const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const opentype = @import("opentype.zig");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Presentation = @import("main.zig").Presentation;
const Variation = @import("main.zig").face.Variation;
const global = @import("../global.zig");
const directwrite = @import("directwrite/main.zig");

const log = std.log.scoped(.discovery);

/// Discover implementation for the compile options.
pub const Discover = switch (options.backend) {
    .freetype => void, // no discovery
    .freetype_windows => Windows,
    .directwrite_freetype => DirectWrite,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, // no discovery
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero
/// value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: ?[:0]const u8 = null,

    /// Specific font style to search for. This will filter the style
    /// string the font advertises. The "bold/italic" booleans later in this
    /// struct filter by the style trait the font has, not the string, so
    /// these can be used in conjunction or not.
    style: ?[:0]const u8 = null,

    /// A codepoint that this font must be able to render.
    codepoint: u32 = 0,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: f32 = 0,

    /// True if we want to search specifically for a font that supports
    /// specific styles.
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// Variation axes to apply to the font. This also impacts searching
    /// for fonts since fonts with the ability to set these variations
    /// will be preferred, but not guaranteed.
    variations: []const Variation = &.{},

    /// Hash the descriptor with the given hasher.
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);

            // This is not correct, but we don't currently depend on the
            // hash value being different based on decimal values of variations.
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    /// Deep copy of the struct. The given allocator is expected to
    /// be an arena allocator of some sort since the descriptor
    /// itself doesn't support fine-grained deallocation of fields.
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        // We can't do any errdefer cleanup in here. As documented we
        // expect the allocator to be an arena so any errors should be
        // cleaned up somewhere else.

        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @intFromEnum(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @intFromEnum(fontconfig.Slant.italic) },
            false,
        ));

        // For fontconfig, we always add monospace in the pattern. Since
        // fontconfig sorts by closeness to the pattern, this doesn't fully
        // exclude non-monospace but helps prefer it.
        assert(pat.add(
            .spacing,
            .{ .integer = @intFromEnum(fontconfig.Spacing.mono) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }

        // Style
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }

        // Codepoint support
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }

        // Set our size attribute if set
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }

        // Build our traits. If we set any, then we store it in the attributes
        // otherwise we do nothing. We determine this by setting up the packed
        // struct, converting to an int, and checking if it is non-zero.
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();

            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );

            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }

        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init(lib: Library) Fontconfig {
        _ = lib;
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;

        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};

pub const CoreText = struct {
    pub fn init(lib: Library) CoreText {
        _ = lib;
        // Required for the "interface" but does nothing for CoreText.
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        _ = self;
    }

    /// Warm up the system font registry.
    ///
    /// The first CoreText query in a process initializes the system font
    /// database, which takes multiple milliseconds, while subsequent
    /// queries are microseconds.
    pub fn warmup() void {
        const name = macos.foundation.String.createWithBytes(
            "AppleColorEmoji",
            .utf8,
            false,
        ) catch return;
        defer name.release();
        const ct_font = macos.text.Font.createWithName(name, 12) catch return;
        ct_font.release();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();

        // Sort our descriptors
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);

        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// Discover a font by its exact name (family, full, or PostScript
    /// name). This is significantly faster than `discover` because it
    /// avoids the system-wide font matching that CTFontCollection does
    /// (which takes multiple milliseconds). This should be preferred
    /// when the desired font is known exactly, e.g. system fonts such
    /// as Apple Color Emoji.
    ///
    /// Returns null if no font with this exact family name exists;
    /// CoreText fallback fonts are never returned.
    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            family,
            .utf8,
            false,
        );
        defer family_str.release();

        // Create our font. We need a size to initialize it so we use size
        // 12 but we will alter the size later (same as DiscoverIterator).
        const ct_font = try macos.text.Font.createWithName(family_str, 12);

        // CTFontCreateWithName never returns null: if the requested font
        // isn't installed it returns a substitute font. Verify we got
        // the family we asked for, otherwise report not found.
        const found: bool = found: {
            const actual = ct_font.copyFamilyName();
            defer actual.release();
            var buf: [256]u8 = undefined;
            const actual_slice = actual.cstring(&buf, .utf8) orelse
                break :found false;
            break :found std.mem.eql(u8, actual_slice, family);
        };
        if (!found) {
            ct_font.release();
            return null;
        }

        return .{ .ct = .{
            .font = ct_font,
            .variations = &.{},
        } };
    }

    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If we have a codepoint within the CJK unified ideographs block
        // then we fallback to macOS to find a font that supports it because
        // there isn't a better way manually with CoreText that I can find that
        // properly takes into account system locale.
        //
        // References:
        // - http://unicode.org/charts/PDF/U4E00.pdf
        // - https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/platform/fonts/LocaleInFonts.md#unified-han-ideographs
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;

            // This is silly but our discover iterator needs a slice so
            // we allocate here. This isn't a performance bottleneck but
            // this is something we can optimize very easily...
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        const it = try self.discover(alloc, desc);

        // If our normal discovery doesn't find anything and we have a specific
        // codepoint, then fallback to using CTFontCreateForString to find a
        // matching font CoreText wants to use. See:
        // https://github.com/ghostty-org/ghostty/issues/2499
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;

            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        return it;
    }

    /// Discover a font for a specific codepoint using the CoreText
    /// CTFontCreateForString API.
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;

        if (comptime options.backend.hasFreetype()) {
            // If we have freetype, we can't use CoreText to find a font
            // that supports a specific codepoint because we need to
            // have a CoreText font to be able to do so.
            return null;
        }

        assert(desc.codepoint > 0);

        // Get our original font. This is dependent on the requested style
        // from the descriptor.
        const original = original: {
            // In all the styles below, we try to match it but if we don't
            // we always fall back to some other option. The order matters
            // here.

            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }

            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }

            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }

            break :original try collection.getFace(.{ .style = .regular });
        };

        // We need it in utf8 format
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );

        // We need a CFString
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();

        // Get our range length for CTFontCreateForString. It looks like
        // the range uses UTF-16 codepoints and not UTF-32 codepoints.
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };

        // Get our font
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();

        // Do not allow the last resort font to go through. This is the
        // last font used by CoreText if it can't find anything else and
        // only contains replacement characters.
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();

            // If the name doesn't fit in our buffer, then it can't
            // be the last resort font so we break out.
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;

            // If the name is "LastResort" then we don't want to use it.
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }

        // Get the descriptor
        return font.copyDescriptor();
    }

    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);

            // We need to retain because once the list is freed it will
            // release all its members.
            result[i].retain();
        }
        return result;
    }

    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        std.mem.sortUnstable(*macos.text.FontDescriptor, list, desc, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score: Score = .score(desc_inner, lhs);
                const rhs_score: Score = .score(desc_inner, rhs);
                // Higher score is "less" (earlier)
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }

    /// We represent our sorting score as a packed struct so that we
    /// can compare scores numerically but build scores symbolically.
    ///
    /// Note that packed structs store their fields from least to most
    /// significant, so the fields here are defined in increasing order
    /// of precedence.
    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

        /// Number of glyphs in the font, if two fonts have identical
        /// scores otherwise then we prefer the one with more glyphs.
        ///
        /// (Number of glyphs clamped at u16 intmax)
        glyph_count: u16 = 0,
        /// A fuzzy match on the style string, less important than
        /// an exact match, and less important than trait matches.
        fuzzy_style: u8 = 0,
        /// Whether the bold-ness of the font matches the descriptor.
        /// This is less important than italic because a font that's italic
        /// when it shouldn't be or not italic when it should be is a bigger
        /// problem (subjectively) than being the wrong weight.
        bold: bool = false,
        /// Whether the italic-ness of the font matches the descriptor.
        /// This is less important than an exact match on the style string
        /// because we want users to be allowed to override trait matching
        /// for the bold/italic/bold italic styles if they want.
        italic: bool = false,
        /// An exact (case-insensitive) match on the style string.
        exact_style: bool = false,
        /// Whether the font is monospace, this is more important than any of
        /// the other fields unless we're looking for a specific codepoint,
        /// in which case that is the most important thing.
        monospace: bool = false,
        /// If we're looking for a codepoint, whether this font has it.
        codepoint: bool = false,

        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }

        fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
            var self: Score = .{};

            // We always load the font if we can since some things can only be
            // inspected on the font itself. Fonts that can't be loaded score
            // 0 automatically because we don't want a font we can't load.
            const font: *macos.text.Font = macos.text.Font.createWithFontDescriptor(
                ct_desc,
                12,
            ) catch return self;
            defer font.release();

            // We prefer fonts with more glyphs, all else being equal.
            {
                const Type = @TypeOf(self.glyph_count);
                self.glyph_count = std.math.cast(
                    Type,
                    font.getGlyphCount(),
                ) orelse std.math.maxInt(Type);
            }

            // If we're searching for a codepoint, then we
            // prioritize fonts that have that codepoint.
            if (desc.codepoint > 0) {
                // Turn UTF-32 into UTF-16 for CT API
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    desc.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;

                // Get our glyphs
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                self.codepoint = font.getGlyphsForCharacters(
                    unichars[0..len],
                    glyphs[0..len],
                );
            }

            // Get our symbolic traits for the descriptor so we can
            // compare boolean attributes like bold, monospace, etc.
            const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
                const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
                defer traits.release();

                const key = macos.text.FontTraitKey.symbolic.key();
                const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                    break :traits .{};

                break :traits macos.text.FontSymbolicTraits.init(symbolic);
            };

            self.monospace = symbolic_traits.monospace;

            // We try to derived data from the font itself, which is generally
            // more reliable than only using the symbolic traits for this.
            const is_bold: bool, const is_italic: bool = derived: {
                // We start with initial guesses based on the symbolic traits,
                // but refine these with more information if we can get it.
                var is_italic = symbolic_traits.italic;
                var is_bold = symbolic_traits.bold;

                // Read the 'head' table out of the font data if it's available.
                if (head: {
                    const tag = macos.text.FontTableTag.init("head");
                    const data = font.copyTable(tag) orelse break :head null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :head opentype.Head.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing head table: {}", .{err});
                        break :head null;
                    };
                }) |head_| {
                    const head: opentype.Head = head_;
                    is_bold = is_bold or (head.macStyle & 1 == 1);
                    is_italic = is_italic or (head.macStyle & 2 == 2);
                }

                // Read the 'OS/2' table out of the font data if it's available.
                if (os2: {
                    const tag = macos.text.FontTableTag.init("OS/2");
                    const data = font.copyTable(tag) orelse break :os2 null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing OS/2 table: {}", .{err});
                        break :os2 null;
                    };
                }) |os2| {
                    is_bold = is_bold or os2.fsSelection.bold;
                    is_italic = is_italic or os2.fsSelection.italic;
                }

                // Check if we have variation axes in our descriptor, if we
                // do then we can derive weight italic-ness or both from them.
                if (font.copyAttribute(.variation_axes)) |axes| variations: {
                    defer axes.release();

                    // Copy the variation values for this instance of the font.
                    // if there are none then we just break out immediately.
                    const values: *macos.foundation.Dictionary =
                        font.copyAttribute(.variation) orelse break :variations;
                    defer values.release();

                    var buf: [1024]u8 = undefined;

                    // If we see the 'ital' value then we ignore 'slnt'.
                    var ital_seen = false;

                    const len = axes.getCount();
                    for (0..len) |i| {
                        const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                        const Key = macos.text.FontVariationAxisKey;
                        const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                        const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                        const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                        const name_str = cf_name.cstring(&buf, .utf8) orelse "";

                        // Default value
                        var def: f64 = 0;
                        _ = cf_def.getValue(.double, &def);
                        // Value in this font
                        var val: f64 = def;
                        if (values.getValue(
                            macos.foundation.Number,
                            cf_id,
                        )) |cf_val| _ = cf_val.getValue(.double, &val);

                        if (std.mem.eql(u8, "wght", name_str)) {
                            // Somewhat subjective threshold, we consider fonts
                            // bold if they have a 'wght' set greater than 600.
                            is_bold = val > 600;
                            continue;
                        }
                        if (std.mem.eql(u8, "ital", name_str)) {
                            is_italic = val > 0.5;
                            ital_seen = true;
                            continue;
                        }
                        if (!ital_seen and std.mem.eql(u8, "slnt", name_str)) {
                            // Arbitrary threshold of anything more than a 5
                            // degree clockwise slant is considered italic.
                            is_italic = val <= -5.0;
                            continue;
                        }
                    }
                }

                break :derived .{ is_bold, is_italic };
            };

            self.bold = desc.bold == is_bold;
            self.italic = desc.italic == is_italic;

            // Get the style string from the font.
            var style_str_buf: [128]u8 = undefined;
            const style_str: []const u8 = style_str: {
                const style = ct_desc.copyAttribute(.style_name) orelse
                    break :style_str "";
                defer style.release();

                break :style_str style.cstring(&style_str_buf, .utf8) orelse "";
            };

            // The first string in this slice will be used for the exact match,
            // and for the fuzzy match, all matching substrings will increase
            // the rank.
            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};

                // If we don't have an explicitly desired style name, we base
                // it on the bold and italic properties, this isn't ideal since
                // fonts may use style names other than these, but it helps in
                // some edge cases.
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };

            self.exact_style = std.ascii.eqlIgnoreCase(
                style_str,
                desired_styles[0],
            );
            // Our "fuzzy match" score is 0 if the desired style isn't present
            // in the string, otherwise we give higher priority for styles that
            // have fewer characters not in the desired_styles list.
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            self.fuzzy_style = @intCast(style_str.len);
            for (desired_styles) |s| {
                if (std.ascii.indexOfIgnoreCase(style_str, s) != null) {
                    self.fuzzy_style -|= @intCast(s.len);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| self.fuzzy_style;

            return self;
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            for (self.list) |desc| {
                desc.release();
            }
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;

            // Get our descriptor. We need to remove the character set
            // limitation because we may have used that to filter but we
            // don't want it anymore because it'll restrict the characters
            // available.
            const desc = desc: {
                // We create a copy, overwriting the character set attribute.
                const attrs = try macos.foundation.MutableDictionary.create(0);
                defer attrs.release();

                attrs.setValue(
                    macos.text.FontAttribute.character_set.key(),
                    macos.c.kCFNull,
                );

                break :desc try macos.text.FontDescriptor.createCopyWithAttributes(
                    self.list[self.i],
                    @ptrCast(attrs),
                );
            };
            defer desc.release();

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .ct = .{
                    .font = font,
                    .variations = self.variations,
                },
            };
        }
    };
};

/// What a discovery backend knows about a font before it is loaded, in the
/// terms `TraitScore` ranks by. A backend fills this from whatever its
/// platform reports; nothing here is platform specific, so the ranking can
/// be tested on any host against fonts read from memory.
pub const Traits = struct {
    /// The font has the descriptor's codepoint. Only meaningful when the
    /// descriptor asks for one.
    has_codepoint: bool = false,
    monospace: bool = false,
    bold: bool = false,
    italic: bool = false,

    /// The style name the font advertises, such as "Bold Italic".
    style: []const u8 = "",

    /// Clamped to what fits.
    glyph_count: u16 = 0,

    /// Refine `bold` and `italic` from the font's own tables, which are
    /// more reliable than what a platform derives: a flag either table
    /// sets is taken, as the CoreText scorer does. Tables that are absent
    /// or do not parse change nothing.
    pub fn refine(self: *Traits, head: ?[]const u8, os2: ?[]const u8) void {
        if (head) |data| {
            if (opentype.Head.init(data)) |table| {
                self.bold = self.bold or (table.macStyle & 1 == 1);
                self.italic = self.italic or (table.macStyle & 2 == 2);
            } else |err| {
                log.warn("error parsing head table: {}", .{err});
            }
        }
        if (os2) |data| {
            if (opentype.OS2.init(data)) |table| {
                self.bold = self.bold or table.fsSelection.bold;
                self.italic = self.italic or table.fsSelection.italic;
            } else |err| {
                log.warn("error parsing OS/2 table: {}", .{err});
            }
        }
    }
};

/// A font's rank for a descriptor, from its `Traits`: the precedence and
/// the style matching of the CoreText scorer, which works on CoreText's
/// own descriptors and is left as it is.
///
/// Packed structs store their fields from least to most significant, so
/// the fields are in increasing order of precedence and two scores compare
/// as integers.
pub const TraitScore = packed struct {
    const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

    /// More glyphs win when everything else is equal.
    glyph_count: u16 = 0,
    /// A fuzzy match on the style string, less important than an exact
    /// match and than the trait matches.
    fuzzy_style: u8 = 0,
    /// Whether the boldness matches the descriptor. Less important than
    /// italic: the wrong slant is the bigger problem of the two.
    bold: bool = false,
    /// Whether the italicness matches the descriptor.
    italic: bool = false,
    /// An exact, case-insensitive match on the style string, so that a
    /// user can override trait matching by naming a style.
    exact_style: bool = false,
    /// Monospace matters more than any style, and less than having the
    /// codepoint that was asked for.
    monospace: bool = false,
    codepoint: bool = false,

    pub fn int(self: TraitScore) Backing {
        return @bitCast(self);
    }

    pub fn init(desc: *const Descriptor, traits: Traits) TraitScore {
        var self: TraitScore = .{
            .glyph_count = traits.glyph_count,
            .monospace = traits.monospace,
            .codepoint = desc.codepoint > 0 and traits.has_codepoint,
            .bold = desc.bold == traits.bold,
            .italic = desc.italic == traits.italic,
        };

        // The first string is the one an exact match is made against;
        // for the fuzzy match every one that occurs raises the rank.
        const desired_styles: []const [:0]const u8 = desired: {
            if (desc.style) |s| break :desired &.{s};

            // Without a style name the bold and italic properties stand
            // in. Fonts name their styles in other ways too, but it
            // helps in some edge cases.
            if (desc.bold) {
                if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                break :desired &.{ "bold", "upright" };
            } else if (desc.italic) {
                break :desired &.{ "italic", "regular", "oblique" };
            }
            break :desired &.{ "regular", "upright" };
        };

        self.exact_style = std.ascii.eqlIgnoreCase(traits.style, desired_styles[0]);

        // Zero when no desired style occurs in the string; otherwise
        // higher the fewer characters of it lie outside the desired ones.
        const Fuzzy = @TypeOf(self.fuzzy_style);
        self.fuzzy_style = std.math.cast(Fuzzy, traits.style.len) orelse
            std.math.maxInt(Fuzzy);
        for (desired_styles) |s| {
            if (std.ascii.indexOfIgnoreCase(traits.style, s) != null) {
                self.fuzzy_style -|= @intCast(s.len);
            }
        }
        self.fuzzy_style = std.math.maxInt(Fuzzy) -| self.fuzzy_style;

        return self;
    }
};

/// DirectWrite font discovery: the fonts of the system font collection,
/// which are the installed ones, for every user and for this one.
///
/// A descriptor's family is looked up by name. The fonts of that family,
/// or every font when there is no family, are ranked by `TraitScore` and
/// returned best first.
///
/// Only fonts that exist are returned. DirectWrite also lists the bold and
/// the oblique it would simulate for a family that has none, and those
/// are left out: a style nobody has is synthesized by the collection,
/// which is where `font-synthetic-style` decides about it. That is also
/// why a family asked for a bold or an italic it does not have answers
/// with nothing rather than with its regular face.
pub const DirectWrite = struct {
    dwrite: *directwrite.Shared,

    /// What opens the fonts that are found, which is asked about each
    /// of them before it is offered.
    lib: Library,

    const api = directwrite.api;

    pub fn init(lib: Library) DirectWrite {
        return .{ .dwrite = lib.dwrite, .lib = lib };
    }

    pub fn deinit(self: *DirectWrite) void {
        _ = self;
    }

    /// Build the system font collection ahead of the first discovery.
    ///
    /// Enumerating the installed fonts is the expensive part of starting
    /// DirectWrite; later queries work on the collection this leaves
    /// behind.
    pub fn warmup() void {
        const shared = directwrite.Shared.get() catch return;
        const collection = shared.systemFonts() catch return;
        api.release(collection);
    }

    pub fn discover(
        self: *const DirectWrite,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        // The fonts that are taken from the collection keep it alive for
        // as long as they need it.
        const collection = try self.dwrite.systemFonts();
        defer api.release(collection);

        var list: std.ArrayListUnmanaged(Candidate) = .empty;
        errdefer {
            for (list.items) |c| api.release(c.font);
            list.deinit(alloc);
        }

        if (desc.family) |family| {
            try collectFamily(alloc, &list, collection, family);
        } else {
            try collectAll(alloc, &list, collection);
        }

        // A family that is asked for a bold or an italic by the trait,
        // not by a style's name, answers with the faces that are one.
        const styled = desc.family != null and
            desc.style == null and
            desc.codepoint == 0;

        // Rank. A font that lacks a codepoint that was asked for is no
        // answer at all, whatever else it matches.
        var i: usize = 0;
        while (i < list.items.len) {
            const c = &list.items[i];
            var style_buf: [128]u8 = undefined;
            const traits = fontTraits(c.font, &desc, &style_buf);
            const keep = keep: {
                if (desc.codepoint > 0 and !traits.has_codepoint) break :keep false;
                if (styled and desc.bold and !traits.bold) break :keep false;
                if (styled and desc.italic and !traits.italic) break :keep false;
                break :keep true;
            };
            if (!keep) {
                api.release(c.font);
                _ = list.swapRemove(i);
                continue;
            }
            c.score = .init(&desc, traits);
            i += 1;
        }
        std.mem.sort(Candidate, list.items, {}, struct {
            fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
                // Higher score is "less" (earlier)
                return lhs.score.int() > rhs.score.int();
            }
        }.lessThan);

        return .{
            .alloc = alloc,
            .lib = self.lib,
            .list = try list.toOwnedSlice(alloc),
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// Discover fonts for a codepoint that the fonts in use lack.
    ///
    /// The first answer is the system's: the font Windows itself shows
    /// the character in, for the user's locale. Every other font that
    /// has the character follows, for the caller that turns the first
    /// one down, and is only looked for then.
    pub fn discoverFallback(
        self: *const DirectWrite,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;

        // The system is asked about a codepoint, in UTF-16. What is none,
        // or is beyond the last one that has an encoding, is not a
        // question for it.
        if (desc.codepoint == 0 or desc.codepoint > 0x10FFFF) {
            return self.discover(alloc, desc);
        }
        const codepoint: u21 = @intCast(desc.codepoint);

        const system = try self.dwrite.systemFonts();
        defer api.release(system);
        const first = self.dwrite.mapCharacter(
            alloc,
            codepoint,
            system,
            desc.bold,
            desc.italic,
        ) orelse return self.discover(alloc, desc);

        return .{
            .alloc = alloc,
            .lib = self.lib,
            .list = &.{},
            .variations = desc.variations,
            .i = 0,
            .first = first,
            .rest = .{ .discover = self.*, .desc = desc },
        };
    }

    const Candidate = struct {
        /// A reference the list owns until the iterator hands it on.
        font: *api.IDWriteFont,
        score: TraitScore = .{},
    };

    /// The fonts of the family with this name.
    fn collectFamily(
        alloc: Allocator,
        list: *std.ArrayListUnmanaged(Candidate),
        collection: *api.IDWriteFontCollection,
        family: [:0]const u8,
    ) !void {
        // UTF-16 never takes more units than UTF-8 takes bytes.
        var wide: [directwrite.name_max]u16 = undefined;
        if (family.len >= wide.len) return;
        const len = std.unicode.utf8ToUtf16Le(&wide, family) catch return;
        wide[len] = 0;

        var index: api.UINT = 0;
        var exists: api.BOOL = 0;
        if (api.succeeded(collection.vtable.FindFamilyName(
            collection,
            wide[0..len :0],
            &index,
            &exists,
        )) and exists != 0) {
            var out: ?*api.IDWriteFontFamily = null;
            if (api.failed(collection.vtable.GetFontFamily(collection, index, &out)))
                return error.DirectWriteFailed;
            const dw_family = out orelse return error.DirectWriteFailed;
            defer api.release(dw_family);
            try appendFonts(alloc, list, dw_family.fontList(), null);
            return;
        }

        // DirectWrite groups fonts by weight, stretch and style, so a name
        // that a font carries as its family, such as "Iosevka Heavy", can
        // be a member of another family here. Those are found by the
        // names the fonts themselves report.
        const count = collection.vtable.GetFontFamilyCount(collection);
        for (0..count) |i| {
            var out: ?*api.IDWriteFontFamily = null;
            if (api.failed(collection.vtable.GetFontFamily(collection, @intCast(i), &out))) continue;
            const dw_family = out orelse continue;
            defer api.release(dw_family);
            try appendFonts(alloc, list, dw_family.fontList(), family);
        }
    }

    /// Every font of the collection.
    fn collectAll(
        alloc: Allocator,
        list: *std.ArrayListUnmanaged(Candidate),
        collection: *api.IDWriteFontCollection,
    ) !void {
        const count = collection.vtable.GetFontFamilyCount(collection);
        for (0..count) |i| {
            var out: ?*api.IDWriteFontFamily = null;
            if (api.failed(collection.vtable.GetFontFamily(collection, @intCast(i), &out))) continue;
            const dw_family = out orelse continue;
            defer api.release(dw_family);
            try appendFonts(alloc, list, dw_family.fontList(), null);
        }
    }

    /// Append the fonts of a family's list: all of them, or the ones
    /// that carry `named` as a family name of their own. The fonts that
    /// DirectWrite simulates are never among them.
    fn appendFonts(
        alloc: Allocator,
        list: *std.ArrayListUnmanaged(Candidate),
        fonts: *api.IDWriteFontList,
        named: ?[]const u8,
    ) !void {
        const count = fonts.vtable.GetFontCount(fonts);
        for (0..count) |i| {
            var out: ?*api.IDWriteFont = null;
            if (api.failed(fonts.vtable.GetFont(fonts, @intCast(i), &out))) continue;
            const font = out orelse continue;
            errdefer api.release(font);

            const keep = keep: {
                if (font.vtable.GetSimulations(font) != api.DWRITE_FONT_SIMULATIONS_NONE)
                    break :keep false;
                const name = named orelse break :keep true;
                break :keep hasFamilyName(font, .WIN32_FAMILY_NAMES, name) or
                    hasFamilyName(font, .TYPOGRAPHIC_FAMILY_NAMES, name);
            };
            if (!keep) {
                api.release(font);
                continue;
            }

            try list.append(alloc, .{ .font = font });
        }
    }

    /// Whether a font carries a name as a family name of its own, in any
    /// of the languages it has one in. A family is asked for by the name
    /// its user knows it by, which is not the English one everywhere,
    /// and FindFamilyName knows the names in every language as well.
    fn hasFamilyName(
        font: *api.IDWriteFont,
        id: api.DWRITE_INFORMATIONAL_STRING_ID,
        name: []const u8,
    ) bool {
        var out: ?*api.IDWriteLocalizedStrings = null;
        var exists: api.BOOL = 0;
        if (api.failed(font.vtable.GetInformationalStrings(font, id, &out, &exists))) return false;
        const strings = out orelse return false;
        defer api.release(strings);
        if (exists == 0) return false;

        var buf: [directwrite.name_max * 3]u8 = undefined;
        for (0..strings.vtable.GetCount(strings)) |i| {
            const value = directwrite.localizedStringAt(
                strings,
                @intCast(i),
                &buf,
            ) catch continue;
            if (std.ascii.eqlIgnoreCase(value, name)) return true;
        }
        return false;
    }

    /// What DirectWrite reports about a font, refined by the font's own
    /// tables when a family narrowed the search: reading tables takes a
    /// font face, which is too much for every font of the system.
    fn fontTraits(
        font: *api.IDWriteFont,
        desc: *const Descriptor,
        style_buf: []u8,
    ) Traits {
        var traits: Traits = .{
            // From semi-bold on. A family whose heaviest face is that one
            // has its bold in it; where there is a bold as well, the
            // style's name ranks it first.
            .bold = @intFromEnum(font.vtable.GetWeight(font)) >= 600,
            .italic = font.vtable.GetStyle(font) != .NORMAL,
        };

        if (desc.codepoint > 0) {
            var exists: api.BOOL = 0;
            if (api.succeeded(font.vtable.HasCharacter(font, desc.codepoint, &exists)))
                traits.has_codepoint = exists != 0;
        }

        if (api.queryInterface(font, api.IDWriteFont1)) |font1| {
            defer api.release(font1);
            traits.monospace = font1.vtable.IsMonospacedFont(font1) != 0;
        } else |_| {}

        style: {
            var out: ?*api.IDWriteLocalizedStrings = null;
            if (api.failed(font.vtable.GetFaceNames(font, &out))) break :style;
            const strings = out orelse break :style;
            defer api.release(strings);
            traits.style = directwrite.localizedString(strings, style_buf) catch "";
        }

        if (desc.family != null) tables: {
            var out: ?*api.IDWriteFontFace = null;
            if (api.failed(font.vtable.CreateFontFace(font, &out))) break :tables;
            const face = out orelse break :tables;
            defer api.release(face);

            const head: Table = .init(face, "head");
            defer head.deinit();
            const os2: Table = .init(face, "OS/2");
            defer os2.deinit();
            traits.refine(head.data, os2.data);
        }

        return traits;
    }

    /// A font table borrowed from a face.
    const Table = struct {
        face: *api.IDWriteFontFace,
        data: ?[]const u8,
        context: ?*anyopaque,

        fn init(face: *api.IDWriteFontFace, tag: *const [4]u8) Table {
            var self: Table = .{ .face = face, .data = null, .context = null };
            var ptr: ?*const anyopaque = null;
            var size: api.UINT = 0;
            var exists: api.BOOL = 0;
            if (api.failed(face.vtable.TryGetFontTable(
                face,
                directwrite.tableTag(tag),
                &ptr,
                &size,
                &self.context,
                &exists,
            ))) return self;
            if (exists == 0) return self;
            const bytes: [*]const u8 = @ptrCast(ptr orelse return self);
            self.data = bytes[0..size];
            return self;
        }

        fn deinit(self: Table) void {
            if (self.data == null) return;
            self.face.vtable.ReleaseFontTable(self.face, self.context);
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        lib: Library,
        list: []const Candidate,
        variations: []const Variation,
        i: usize,

        /// The system's answer to a search for a codepoint, which goes
        /// before the list. A reference this owns until it is handed on.
        first: ?*api.IDWriteFont = null,

        /// The search that fills the list once the first answer is gone:
        /// going through every font is work that the first answer
        /// usually saves.
        rest: ?struct {
            discover: DirectWrite,
            desc: Descriptor,
        } = null,

        pub fn deinit(self: *DiscoverIterator) void {
            if (self.first) |font| api.release(font);
            for (self.list[self.i..]) |c| api.release(c.font);
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.first) |font| {
                self.first = null;
                if (self.offer(font)) |face| return face;
            }

            if (self.rest) |rest| {
                self.rest = null;
                var it = try rest.discover.discover(self.alloc, rest.desc);
                self.alloc.free(self.list);
                self.list = it.list;
                self.i = 0;
                it.list = &.{};
                it.deinit();
            }

            while (self.i < self.list.len) {
                const font = self.list[self.i].font;
                self.i += 1;
                if (self.offer(font)) |face| return face;
            }

            return null;
        }

        /// The deferred face of a font, which takes the font's reference,
        /// or null for a font that cannot be loaded, whose reference is
        /// dropped.
        fn offer(self: *const DiscoverIterator, font: *api.IDWriteFont) ?DeferredFace {
            // What DirectWrite finds, FreeType has to load. A font that
            // it does not load is not offered: one that is offered and
            // then fails to load is not a font that was not found, which
            // has the fonts that are built in to fall back on, but a
            // font grid that cannot be made.
            if (comptime options.backend.hasFreetype()) {
                if (!self.canLoad(font)) {
                    api.release(font);
                    return null;
                }
            }

            return .{ .dw = .{
                .font = font,
                .presentation = presentation(font),
                .variations = self.variations,
            } };
        }

        /// Whether FreeType loads a font. It opens files, by a name it
        /// can pass on, and takes the characters of a font from a
        /// Unicode character map, which the symbol fonts of Windows
        /// (Webdings, Wingdings, Symbol, Marlett) do not have.
        ///
        /// The question is put to what loads the font later, so the
        /// answer is the one that loading gets, whatever the reason.
        fn canLoad(self: *const DiscoverIterator, font: *api.IDWriteFont) bool {
            // The font is borrowed for the length of the call.
            var deferred: DeferredFace = .{ .dw = .{
                .font = font,
                .presentation = .text,
                .variations = self.variations,
            } };
            var face = deferred.load(self.lib, .{ .size = .{ .points = 12 } }) catch |err| {
                var buf: [directwrite.name_max]u8 = undefined;
                log.info("font skipped, it does not load: {s} err={}", .{
                    deferred.name(&buf) catch "unknown",
                    err,
                });
                return false;
            };
            face.deinit();
            return true;
        }

        fn presentation(font: *api.IDWriteFont) Presentation {
            const font2 = api.queryInterface(font, api.IDWriteFont2) catch return .text;
            defer api.release(font2);
            return if (font2.vtable.IsColorFont(font2) != 0) .emoji else .text;
        }
    };
};

/// Windows font discovery. Enumerates font files in the system and
/// per-user font directories and matches them to a descriptor via
/// FreeType's family_name field (with a fallback to the SFNT name
/// table when family_name is missing).
///
/// No external service is used; each discover() call walks the
/// directories, opening candidate files with FreeType only as needed.
/// For typical Windows installations (~300 fonts) a name query is in
/// the tens of milliseconds. A codepoint fallback query may be
/// noticeably slower because every candidate has to be opened to
/// probe its CMap.
pub const Windows = struct {
    lib: Library,

    pub fn init(lib: Library) Windows {
        return .{ .lib = lib };
    }

    pub fn deinit(self: *Windows) void {
        _ = self;
    }

    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        return .{
            .alloc = alloc,
            .lib = self.lib,
            .desc = desc,
            .variations = desc.variations,
            .state = .system,
            .dir = null,
            .iter = null,
            .system_path = null,
            .user_path = null,
        };
    }

    pub fn discoverFallback(
        self: *const Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        lib: Library,
        desc: Descriptor,
        variations: []const Variation,
        state: State,
        dir: ?std.Io.Dir,
        iter: ?std.Io.Dir.Iterator,
        system_path: ?[:0]const u8,
        user_path: ?[:0]const u8,

        const State = enum { system, user, done };

        pub fn deinit(self: *DiscoverIterator) void {
            if (self.dir) |*d| d.close(global.io());
            if (self.system_path) |p| self.alloc.free(p);
            if (self.user_path) |p| self.alloc.free(p);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            while (true) {
                // Ensure we have a directory iterator for the current state.
                if (self.iter == null) {
                    switch (self.state) {
                        .system => {
                            const path = self.systemFontsPath() orelse {
                                self.state = .user;
                                continue;
                            };
                            self.system_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .user;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .user => {
                            const path = self.userFontsPath() orelse {
                                self.state = .done;
                                continue;
                            };
                            self.user_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .done;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .done => return null,
                    }
                }

                const entry = (self.iter.?.next(global.io()) catch null) orelse {
                    // Finished this directory; advance state.
                    if (self.dir) |*d| d.close(global.io());
                    self.dir = null;
                    self.iter = null;
                    self.state = switch (self.state) {
                        .system => .user,
                        .user => .done,
                        .done => .done,
                    };
                    continue;
                };

                if (entry.kind != .file) continue;
                if (!isFontFile(entry.name)) continue;

                if (try self.tryMatch(entry.name)) |face| return face;
            }
        }

        /// Build the system fonts directory from %SYSTEMROOT%. Returns null
        /// if SYSTEMROOT is unset, which shouldn't happen on a healthy
        /// Windows install but we just skip the directory rather than
        /// falling back to a hardcoded drive letter.
        fn systemFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const systemroot = global.environ().getAlloc(
                self.alloc,
                "SYSTEMROOT",
            ) catch return null;
            defer self.alloc.free(systemroot);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Fonts",
                .{systemroot},
                0,
            ) catch null;
        }

        fn userFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const local_appdata = global.environ().getAlloc(
                self.alloc,
                "LOCALAPPDATA",
            ) catch return null;
            defer self.alloc.free(local_appdata);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Microsoft\\Windows\\Fonts",
                .{local_appdata},
                0,
            ) catch null;
        }

        fn tryMatch(
            self: *DiscoverIterator,
            name: []const u8,
        ) !?DeferredFace {
            const dir_path = switch (self.state) {
                .system => self.system_path.?,
                .user => self.user_path.?,
                .done => return null,
            };

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(
                &path_buf,
                "{s}\\{s}",
                .{ dir_path, name },
            ) catch return null;

            const is_ttc = std.ascii.endsWithIgnoreCase(name, ".ttc");
            const max_faces: i32 = if (is_ttc) 16 else 1;

            // Probe each face in the file.
            var face_index: i32 = 0;
            while (face_index < max_faces) : (face_index += 1) {
                var face = Face.initFile(
                    self.lib,
                    full_path,
                    face_index,
                    .{ .size = .{ .points = 12 } },
                ) catch break;

                if (self.matches(&face)) {
                    return try self.makeDeferred(face, full_path, face_index);
                }

                face.deinit();
            }

            return null;
        }

        /// Check whether the given face matches the descriptor.
        fn matches(self: *const DiscoverIterator, face: *Face) bool {
            if (self.desc.family) |family| {
                if (!familyMatches(face, family)) return false;
            }
            if (self.desc.codepoint != 0) {
                if (face.glyphIndex(self.desc.codepoint) == null) return false;
            }
            return true;
        }

        fn makeDeferred(
            self: *DiscoverIterator,
            face: Face,
            full_path: []const u8,
            face_index: i32,
        ) !DeferredFace {
            const path_owned = try self.alloc.dupeZ(u8, full_path);
            errdefer self.alloc.free(path_owned);

            const presentation: Presentation =
                if (face.hasColor()) .emoji else .text;

            return DeferredFace{
                .win = .{
                    .path = path_owned,
                    .face_index = face_index,
                    .variations = self.variations,
                    .peek = face,
                    .presentation = presentation,
                    .alloc = self.alloc,
                },
            };
        }
    };

    fn isFontFile(name: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(name, ".ttf") or
            std.ascii.endsWithIgnoreCase(name, ".ttc") or
            std.ascii.endsWithIgnoreCase(name, ".otf");
    }

    /// Compare a face's family against a requested family name. Checks
    /// FreeType's family_name first, then falls back to the SFNT name
    /// table entry.
    fn familyMatches(face: *Face, family: [:0]const u8) bool {
        const ft_family: ?[*:0]const u8 = face.face.handle.*.family_name;
        if (ft_family) |f| {
            if (std.ascii.eqlIgnoreCase(std.mem.span(f), family)) return true;
        }
        var buf: [256]u8 = undefined;
        const sfnt = face.name(&buf) catch "";
        return sfnt.len > 0 and std.ascii.eqlIgnoreCase(sfnt, family);
    }
};

test "descriptor hash" {
    const testing = std.testing;

    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}

test "descriptor hash family names" {
    const testing = std.testing;

    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}

test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    var face = (try it.next()).?;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}

test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext sorting" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//
    // FIXME: Disabled for now because SF Pro is not available in CI
    //        The solution likely involves directly testing that the
    //        `sortMatchingDescriptors` function sorts a bundled test
    //        font correctly, instead of relying on the system fonts.
    if (true) return error.SkipZigTest;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();

    // We try to get a Regular, Italic, Bold, & Bold Italic version of SF Pro,
    // which should be installed on all Macs, and has many styles which makes
    // it a good test, since there will be many results for each discovery.

    // Regular
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular", name);
    }

    // Regular Italic
    //
    // NOTE: This makes sure that we don't accidentally prefer "Thin Italic",
    //       which we previously did, because it has a shorter name.
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular Italic", name);
    }

    // Bold
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold", name);
    }

    // Bold Italic
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold Italic", name);
    }
}

test "windows" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    // Arial ships on every stock Windows install.
    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12 });
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));
}

test "trait score" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const embedded = @import("main.zig").embedded;

    // The four static faces of one family, with what a platform reports
    // before a table is read: the style name and nothing else.
    const faces = [_]struct { data: []const u8, style: []const u8 }{
        .{ .data = embedded.regular, .style = "Regular" },
        .{ .data = embedded.bold, .style = "Bold" },
        .{ .data = embedded.italic, .style = "Italic" },
        .{ .data = embedded.bold_italic, .style = "Bold Italic" },
    };
    var traits: [faces.len]Traits = undefined;
    for (faces, &traits) |face, *t| {
        const sfnt = try opentype.sfnt.SFNT.init(face.data, alloc);
        defer sfnt.deinit(alloc);
        t.* = .{ .style = face.style, .monospace = true };
        t.refine(sfnt.getTable("head"), sfnt.getTable("OS/2"));
    }

    // The tables carry the styles.
    try testing.expect(!traits[0].bold and !traits[0].italic);
    try testing.expect(traits[1].bold and !traits[1].italic);
    try testing.expect(!traits[2].bold and traits[2].italic);
    try testing.expect(traits[3].bold and traits[3].italic);

    const best = struct {
        fn best(desc: Descriptor, candidates: []const Traits) usize {
            var result: usize = 0;
            for (candidates, 0..) |t, i| {
                const score: TraitScore = .init(&desc, t);
                const leader: TraitScore = .init(&desc, candidates[result]);
                if (score.int() > leader.int()) result = i;
            }
            return result;
        }
    }.best;

    // Each style that is asked for by its traits is the first result.
    try testing.expectEqual(0, best(.{ .family = "JetBrains Mono" }, &traits));
    try testing.expectEqual(1, best(.{ .family = "JetBrains Mono", .bold = true }, &traits));
    try testing.expectEqual(2, best(.{ .family = "JetBrains Mono", .italic = true }, &traits));
    try testing.expectEqual(3, best(.{
        .family = "JetBrains Mono",
        .bold = true,
        .italic = true,
    }, &traits));

    // A style that is asked for by name wins over the traits, which are
    // unset then, in any case of letters.
    try testing.expectEqual(1, best(.{ .family = "JetBrains Mono", .style = "bold" }, &traits));
    try testing.expectEqual(3, best(.{
        .family = "JetBrains Mono",
        .style = "Bold Italic",
    }, &traits));

    // Where nothing else differs the style's name decides: the fewer
    // characters of it lie outside what was asked for, the better.
    {
        const desc: Descriptor = .{ .family = "A", .bold = true };
        const short: TraitScore = .init(&desc, .{ .bold = true, .style = "Bold Condensed" });
        const long: TraitScore = .init(&desc, .{ .bold = true, .style = "Bold Extended Condensed" });
        try testing.expect(short.int() > long.int());
    }
    {
        const desc: Descriptor = .{ .family = "A", .style = "semibold" };
        const hit: TraitScore = .init(&desc, .{ .italic = true, .style = "SemiBold Italic" });
        const miss: TraitScore = .init(&desc, .{ .italic = true, .style = "Light Italic" });
        try testing.expect(hit.int() > miss.int());
    }

    // The exact name outranks a name that contains it.
    {
        const desc: Descriptor = .{ .family = "A", .style = "bold" };
        const exact: TraitScore = .init(&desc, .{ .style = "Bold" });
        const contains: TraitScore = .init(&desc, .{ .style = "Bold Italic" });
        try testing.expect(exact.int() > contains.int());
    }

    // The slant outranks the weight: of two faces that match one of the
    // two, the one with the right slant is the better.
    {
        const desc: Descriptor = .{ .family = "A", .bold = true, .italic = true };
        const slant: TraitScore = .init(&desc, .{ .italic = true, .style = "x" });
        const weight: TraitScore = .init(&desc, .{ .bold = true, .style = "x" });
        try testing.expect(slant.int() > weight.int());
    }

    // A codepoint that nobody asked for counts for nothing.
    {
        const desc: Descriptor = .{ .family = "A" };
        const has: TraitScore = .init(&desc, .{ .has_codepoint = true, .style = "Regular" });
        const lacks: TraitScore = .init(&desc, .{ .style = "Regular" });
        try testing.expectEqual(lacks.int(), has.int());
    }

    // Having the codepoint outranks every style.
    {
        const desc: Descriptor = .{ .codepoint = 'A', .bold = true };
        var with = traits[0];
        with.has_codepoint = true;
        const has: TraitScore = .init(&desc, with);
        const lacks: TraitScore = .init(&desc, traits[1]);
        try testing.expect(has.int() > lacks.int());
    }

    // Monospace outranks a style, and a codepoint outranks monospace.
    {
        const desc: Descriptor = .{ .codepoint = 'A', .bold = true };
        var proportional = traits[1];
        proportional.monospace = false;
        const mono_regular: TraitScore = .init(&desc, traits[0]);
        const proportional_bold: TraitScore = .init(&desc, proportional);
        try testing.expect(mono_regular.int() > proportional_bold.int());
        proportional.has_codepoint = true;
        const proportional_has: TraitScore = .init(&desc, proportional);
        try testing.expect(proportional_has.int() > mono_regular.int());
    }
}

test "directwrite" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var dw = DirectWrite.init(lib);
    defer dw.deinit();

    var buf: [256]u8 = undefined;

    // Arial ships with every Windows. Without a style the regular face
    // is the first result.
    {
        var it = try dw.discover(alloc, .{ .family = "Arial", .size = 12 });
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        try testing.expect(face.hasCodepoint('A', null));
        try testing.expectEqualStrings("Arial", try face.familyName(&buf));
        try testing.expectEqualStrings("Arial", try face.name(&buf));
    }

    // The styles, by their traits and in any case of the family's letters.
    {
        var it = try dw.discover(alloc, .{ .family = "arial", .size = 12, .bold = true });
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        try testing.expectEqualStrings("Arial Bold", try face.name(&buf));
    }
    {
        var it = try dw.discover(alloc, .{
            .family = "Arial",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        try testing.expectEqualStrings("Arial Bold Italic", try face.name(&buf));
    }

    // A family that has no bold answers a request for one with nothing,
    // so that the collection synthesizes it, and has no simulated face
    // among its fonts.
    {
        var it = try dw.discover(alloc, .{
            .family = "Lucida Console",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        try testing.expect(try it.next() == null);
    }
    {
        var it = try dw.discover(alloc, .{ .family = "Lucida Console", .size = 12 });
        defer it.deinit();
        var count: usize = 0;
        while (try it.next()) |deferred| {
            var face = deferred;
            defer face.deinit();
            count += 1;
        }
        try testing.expectEqual(1, count);
    }

    // A symbol font has no Unicode character map, which FreeType takes
    // the characters of a font from. It is found, and is not offered
    // to what cannot load it: a family that fails to load fails the
    // font grid, where a family that is not found leaves the fonts that
    // are built in.
    for ([_][:0]const u8{ "Webdings", "Wingdings", "Symbol" }) |family| {
        var it = try dw.discover(alloc, .{ .family = family, .size = 12 });
        defer it.deinit();
        try testing.expectEqual(1, it.list.len);
        if (comptime !options.backend.hasFreetype()) continue;
        try testing.expect(try it.next() == null);
    }

    // Every font that is offered loads.
    {
        var it = try dw.discover(alloc, .{ .size = 12 });
        defer it.deinit();
        var count: usize = 0;
        while (try it.next()) |deferred| {
            var face = deferred;
            defer face.deinit();
            var loaded = try face.load(lib, .{ .size = .{ .points = 12 } });
            loaded.deinit();
            count += 1;
        }
        try testing.expect(count > 0);
    }

    // Every result of a search for a codepoint has the codepoint.
    {
        var it = try dw.discover(alloc, .{ .codepoint = 0x4E2D, .size = 12 });
        defer it.deinit();
        var count: usize = 0;
        while (try it.next()) |deferred| {
            var face = deferred;
            defer face.deinit();
            try testing.expect(face.hasCodepoint(0x4E2D, null));
            count += 1;
        }
        try testing.expect(count > 0);
    }

    // A family nobody has yields nothing.
    {
        var it = try dw.discover(alloc, .{ .family = "No Such Family 7f3a", .size = 12 });
        defer it.deinit();
        try testing.expect(try it.next() == null);
    }
}

test "directwrite collection member" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();
    var dw = DirectWrite.init(lib);
    defer dw.deinit();

    // A face that is not the first of its collection file loads as
    // itself: the index comes from DirectWrite.
    var it = try dw.discover(alloc, .{ .family = "Cambria Math", .size = 12 });
    defer it.deinit();
    var deferred = (try it.next()) orelse return error.SkipZigTest;
    defer deferred.deinit();

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Cambria Math", try deferred.name(&buf));
    var face = try deferred.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // A mathematical bold capital is in Cambria Math and not in Cambria,
    // which is the first face of the same file.
    try testing.expect(face.glyphIndex(0x1D400) != null);
}

test "directwrite family of another family" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();
    var dw = DirectWrite.init(lib);
    defer dw.deinit();

    // Arial Black carries a family name of its own and is the heaviest
    // weight of Arial to DirectWrite. Where DirectWrite knows it as a
    // family this test has nothing to show.
    const api = directwrite.api;
    {
        const collection = try lib.dwrite.systemFonts();
        defer api.release(collection);
        var index: api.UINT = 0;
        var exists: api.BOOL = 0;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("Arial Black");
        if (api.succeeded(collection.vtable.FindFamilyName(
            collection,
            name,
            &index,
            &exists,
        )) and exists != 0) return error.SkipZigTest;
    }

    var it = try dw.discover(alloc, .{ .family = "Arial Black", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |deferred| {
        var face = deferred;
        defer face.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("Arial", try face.familyName(&buf));
        try testing.expectEqualStrings("Arial Black", try face.name(&buf));
        count += 1;
    }
    if (count == 0) return error.SkipZigTest;
}

test "directwrite family of another family, in another language" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();
    var dw = DirectWrite.init(lib);
    defer dw.deinit();

    // The light weight of Microsoft JhengHei carries a family name of its
    // own, in English and in Chinese. Where the font is not installed,
    // or loads from no file, this test has nothing to show.
    var want_buf: [256]u8 = undefined;
    const want = want: {
        var it = try dw.discover(alloc, .{ .family = "Microsoft JhengHei Light", .size = 12 });
        defer it.deinit();
        var face = (try it.next()) orelse return error.SkipZigTest;
        defer face.deinit();
        break :want try face.name(&want_buf);
    };

    // A name that is not ASCII is compared as it is written.
    var it = try dw.discover(alloc, .{ .family = "微軟正黑體 Light", .size = 12 });
    defer it.deinit();
    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(want, try face.name(&buf));
    try testing.expectEqualStrings("Microsoft JhengHei", try face.familyName(&buf));
}

test "directwrite instance of a variable font" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;
    if (comptime !options.backend.hasFreetype()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();
    var dw = DirectWrite.init(lib);
    defer dw.deinit();

    // Bahnschrift is one file with a weight axis; its weights are
    // instances of it that share the file and the index in it. What is
    // loaded has to be the instance that was found.
    const Want = struct { bold: bool, weight: i32 };
    for ([_]Want{
        .{ .bold = false, .weight = 400 },
        .{ .bold = true, .weight = 700 },
    }) |want| {
        var it = try dw.discover(alloc, .{
            .family = "Bahnschrift",
            .size = 12,
            .bold = want.bold,
            .style = if (want.bold) "Bold" else "Regular",
        });
        defer it.deinit();
        var deferred = (try it.next()) orelse return error.SkipZigTest;
        defer deferred.deinit();

        var face = try deferred.load(lib, .{ .size = .{ .points = 12 } });
        defer face.deinit();
        if (!face.face.hasMultipleMasters()) return error.SkipZigTest;

        const mm = try face.face.getMMVar();
        defer lib.lib.doneMMVar(mm);
        var coords_buf: [32]@TypeOf(mm.axis[0].def) = undefined;
        const coords = coords_buf[0..@min(coords_buf.len, mm.num_axis)];
        try face.face.getVarDesignCoordinates(coords);

        const wght: u32 = @bitCast(Variation.Id.init("wght"));
        var found = false;
        for (0..coords.len) |i| {
            if (mm.axis[i].tag != wght) continue;
            // 16.16 fixed point.
            try testing.expectEqual(want.weight, @as(i32, @intCast(coords[i] >> 16)));
            found = true;
        }
        try testing.expect(found);
    }
}

test "directwrite fallback" {
    if (comptime !options.backend.hasDirectWrite()) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const api = directwrite.api;

    var lib = try Library.init(alloc);
    defer lib.deinit();
    var dw = DirectWrite.init(lib);
    defer dw.deinit();
    var c = Collection.init();
    defer c.deinit(alloc);

    // The system has a font for each of these: Han, Devanagari, a symbol
    // and an emoji.
    for ([_]u21{ 0x4E2D, 0x0905, 0x2605, 0x1F600 }) |cp| {
        // The system's answer is there, and has the codepoint.
        {
            const system = try lib.dwrite.systemFonts();
            defer api.release(system);
            const font = lib.dwrite.mapCharacter(alloc, cp, system, false, false) orelse
                return error.TestFontNotFound;
            defer api.release(font);
            var exists: api.BOOL = 0;
            try testing.expect(api.succeeded(font.vtable.HasCharacter(font, cp, &exists)));
            try testing.expect(exists != 0);
        }

        // It is the first result, and the others follow for a caller that
        // turns it down.
        var it = try dw.discoverFallback(alloc, &c, .{ .codepoint = cp, .size = 12 });
        defer it.deinit();
        const first = it.first orelse return error.TestFontNotFound;

        // A font that cannot be loaded is not offered, the system's
        // answer included, and the search goes on without it.
        const offered = (comptime !options.backend.hasFreetype()) or
            it.canLoad(first);

        var count: usize = 0;
        while (try it.next()) |deferred| {
            var face = deferred;
            defer face.deinit();

            // The face takes the font that the iterator held, so it is
            // the same object and not only the same font.
            if (count == 0 and offered) {
                try testing.expectEqual(first, face.dw.?.font);
            }
            try testing.expect(face.hasCodepoint(cp, null));
            count += 1;
        }
        try testing.expect(count > 1);
    }

    // An emoji comes in a font that presents as emoji.
    {
        var it = try dw.discoverFallback(alloc, &c, .{ .codepoint = 0x1F600, .size = 12 });
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        try testing.expect(face.hasCodepoint(0x1F600, .emoji));
    }

    // An iterator that is dropped with the first answer still in it gives
    // up its reference to the font. The font is DirectWrite's, which the
    // allocator of the test does not see, so its count is read: between
    // a reference that the test takes and gives up again, the iterator's
    // goes, and two are gone. The counts are compared with each other
    // and not with a number, since DirectWrite holds the font as well.
    {
        var it = try dw.discoverFallback(alloc, &c, .{ .codepoint = 0x4E2D, .size = 12 });
        const font = it.first orelse {
            it.deinit();
            return error.TestFontNotFound;
        };
        const unk = api.unknown(font);
        const held = unk.vtable.AddRef(unk);
        it.deinit();
        const left = unk.vtable.Release(unk);
        try testing.expectEqual(held - 2, left);
    }

    // What is no codepoint is not asked of the system and is in no font:
    // there is no first answer, and the search ends with nothing.
    {
        var it = try dw.discoverFallback(alloc, &c, .{ .codepoint = 0x110000, .size = 12 });
        defer it.deinit();
        try testing.expect(it.first == null);
        try testing.expect(it.rest == null);
        try testing.expect(try it.next() == null);
    }

    // DirectWrite had a text source for the length of each call and kept
    // none of them.
    try testing.expectEqual(0, directwrite.TextAnalysisSource.live.load(.monotonic));
}
