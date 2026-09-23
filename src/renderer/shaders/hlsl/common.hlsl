// Common definitions shared across the Direct3D 11 shaders. The first line
// of any shader that needs these is `#include "common.hlsl"`, which the
// backend expands when it embeds the source (d3d11/shaders.zig).
//
// This is the HLSL twin of glsl/common.glsl: the same constant buffer, the
// same unpacking and color functions, so the two stay comparable line by
// line. The constant buffer mirrors the OpenGL Globals block: the same
// u32-packed scalars in the same order at the same offsets, which the
// packoffset annotations pin and a test in d3d11/shaders.zig checks.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
cbuffer Globals : register(b1) {
    float4x4 projection_matrix : packoffset(c0);
    float2 screen_size : packoffset(c4.x);
    float2 cell_size : packoffset(c4.z);
    uint grid_size_packed_2u16 : packoffset(c5.x);
    float4 grid_padding : packoffset(c6);
    uint padding_extend : packoffset(c7.x);
    float min_contrast : packoffset(c7.y);
    uint cursor_pos_packed_2u16 : packoffset(c7.z);
    uint cursor_color_packed_4u8 : packoffset(c7.w);
    uint bg_color_packed_4u8 : packoffset(c8.x);
    uint bools : packoffset(c8.y);
};

// Bools
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0) & 0xFFu,
        (packed_value >> 8) & 0xFFu,
        (packed_value >> 16) & 0xFFu,
        (packed_value >> 24) & 0xFFu
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0) & 0xFFFFu,
        (packed_value >> 16) & 0xFFFFu
    );
}

int2 unpack2i16(int packed_value) {
    return int2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
//
// One return rather than the GLSL's early returns: fxc warns about a
// possibly uninitialized result for those.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    float4 result = fg;
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0, 0.0, 0.0), bg.rgb);
        result = (white_ratio > black_ratio)
            ? float4(1.0, 1.0, 1.0, 1.0)
            : float4(0.0, 0.0, 0.0, 1.0);
    }

    return result;
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
    float3 cutoff = (float3)(srgb.rgb <= float3(0.04045, 0.04045, 0.04045));
    float3 higher = pow((srgb.rgb + float3(0.055, 0.055, 0.055)) / float3(1.055, 1.055, 1.055), float3(2.4, 2.4, 2.4));
    float3 lower = srgb.rgb / float3(12.92, 12.92, 12.92);

    return float4(lerp(higher, lower, cutoff), srgb.a);
}
float linearize_scalar(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear_color) {
    float3 cutoff = (float3)(linear_color.rgb <= float3(0.0031308, 0.0031308, 0.0031308));
    float3 higher = pow(linear_color.rgb, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) * float3(1.055, 1.055, 1.055) - float3(0.055, 0.055, 0.055);
    float3 lower = linear_color.rgb * float3(12.92, 12.92, 12.92);

    return float4(lerp(higher, lower, cutoff), linear_color.a);
}
float unlinearize_scalar(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// `to_linear` controls whether the returned color is linear or gamma encoded.
float4 load_color(
    uint4 in_color,
    bool to_linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    float4 color = float4(in_color) / float4(255.0f, 255.0f, 255.0f, 255.0f);

    // Linearize if necessary.
    if (to_linear) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

//----------------------------------------------------------------------------//
