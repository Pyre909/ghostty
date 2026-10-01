const std = @import("std");

pub const Backend = enum {
    const WasmTarget = @import("../os/wasm/target.zig").Target;

    /// FreeType for font rendering with no font discovery enabled.
    freetype,

    /// FreeType for font rendering with a built-in Windows font directory
    /// scanner (C:\Windows\Fonts + %LOCALAPPDATA%\Microsoft\Windows\Fonts).
    /// Needs nothing of DirectWrite; matches by family_name and SFNT
    /// name table without any external index.
    freetype_windows,

    /// DirectWrite for font discovery, FreeType for rendering, and
    /// HarfBuzz for shaping (Windows). Needs the DirectWrite of Windows
    /// 8.1 (IDWriteFactory2, for the system's font fallback); the
    /// interfaces of later Windows are used where they are and done
    /// without where they are not.
    directwrite_freetype,

    /// DirectWrite for font discovery and rendering, HarfBuzz for
    /// shaping (Windows). Needs the DirectWrite of Windows 8.1
    /// (IDWriteFactory2, which rasterizes glyphs that are not fitted
    /// to the pixel grid and translates color layers); variable fonts
    /// and color images need the interfaces of Windows 10 and are done
    /// without where they are not.
    directwrite,

    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// CoreText for font discovery, rendering, and shaping (macOS).
    coretext,

    /// CoreText for font discovery, FreeType for rendering, and
    /// HarfBuzz for shaping (macOS).
    coretext_freetype,

    /// CoreText for font discovery and rendering, HarfBuzz for shaping
    coretext_harfbuzz,

    /// CoreText for font discovery and rendering, no shaping.
    coretext_noshape,

    /// Use the browser font system and the Canvas API (wasm). This limits
    /// the available fonts to browser fonts (anything Canvas natively
    /// supports).
    web_canvas,

    /// Returns the default backend for a build environment. This is
    /// meant to be called at comptime by the build.zig script. To get the
    /// backend look at build_options.
    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .web_canvas,
            };
        }

        if (target.os.tag == .windows) {
            // Avoid fontconfig on Windows because its libxml2 dependency
            // may not unpack due to symlinks. DirectWrite finds the fonts
            // instead: it knows them by the names and the styles Windows
            // shows them under, and knows the font the system shows a
            // character in. It draws them too, as CoreText does on macOS.
            // FreeType's drawing stays available as "directwrite_freetype",
            // and the scanner of the font directories as "freetype_windows".
            return .directwrite;
        }

        // macOS also supports "coretext_freetype" but there is no scenario
        // that is the default. It is only used by people who want to
        // self-compile Ghostty and prefer the freetype aesthetic.
        return if (target.os.tag.isDarwin()) .coretext else .fontconfig_freetype;
    }

    // All the functions below can be called at comptime or runtime to
    // determine if we have a certain dependency.

    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .directwrite_freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => true,

            .directwrite,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }

    pub fn hasCoretext(self: Backend) bool {
        return switch (self) {
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            => true,

            .freetype,
            .freetype_windows,
            .directwrite_freetype,
            .directwrite,
            .fontconfig_freetype,
            .web_canvas,
            => false,
        };
    }

    pub fn hasFontconfig(self: Backend) bool {
        return switch (self) {
            .fontconfig_freetype => true,

            .freetype,
            .freetype_windows,
            .directwrite_freetype,
            .directwrite,
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }

    pub fn hasDirectWrite(self: Backend) bool {
        return switch (self) {
            .directwrite_freetype,
            .directwrite,
            => true,

            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }

    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .directwrite_freetype,
            .directwrite,
            .fontconfig_freetype,
            .coretext_freetype,
            .coretext_harfbuzz,
            => true,

            .coretext,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }
};
