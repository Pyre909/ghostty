#include "common.hlsl"

// The full-screen background image; the twin of glsl/bg_image.v.glsl.
// The single instance is the BgImage struct in d3d11/shaders.zig.
Texture2D<float4> image : register(t0);

struct VertexIn {
    float in_opacity : OPACITY;
    uint info : INFO;
    uint vid : SV_VertexID;
};

struct VertexOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat : TEXCOORD3;
};

// 4 bits of info.
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

VertexOut main(VertexIn in_data) {
    VertexOut out_data;

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    uint vid = in_data.vid;

    // Single triangle is clipped to viewport.
    //
    // X <- vid == 0: (-1, -3)
    // |\
    // | \
    // |  \
    // |###\
    // |#+# \ `+` is (0, 0). `#`s are viewport area.
    // |###  \
    // X------X <- vid == 2: (3, 1)
    // ^
    // vid == 1: (-1, 1)
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 0.5;
    position.w = 1.0;
    out_data.position = position;

    out_data.opacity = in_data.in_opacity;

    out_data.repeat = in_data.info & BG_IMAGE_REPEAT;

    uint width, height;
    image.GetDimensions(width, height);
    float2 tex_size = float2(width, height);

    // The GLSL switches on the fit and position bits; these branches are
    // the same cases in the same order.
    float2 dest_size = tex_size;
    uint fit = in_data.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        // For `contain` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is smaller.
        float factor = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * factor;
    } else if (fit == BG_IMAGE_COVER) {
        // For `cover` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is larger.
        float factor = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * factor;
    } else if (fit == BG_IMAGE_STRETCH) {
        // For `stretch` we stretch the image to the size of
        // the screen without worrying about aspect ratio.
        dest_size = screen_size;
    } else {
        // For `none` we just use the original texture size.
        dest_size = tex_size;
    }

    float2 start = float2(0.0, 0.0);
    float2 mid = (screen_size - dest_size) / 2.0;
    float2 end = screen_size - dest_size;

    float2 dest_offset = mid;
    uint pos = in_data.info & BG_IMAGE_POSITION;
    if (pos == BG_IMAGE_TL) {
        dest_offset = float2(start.x, start.y);
    } else if (pos == BG_IMAGE_TC) {
        dest_offset = float2(mid.x, start.y);
    } else if (pos == BG_IMAGE_TR) {
        dest_offset = float2(end.x, start.y);
    } else if (pos == BG_IMAGE_ML) {
        dest_offset = float2(start.x, mid.y);
    } else if (pos == BG_IMAGE_MC) {
        dest_offset = float2(mid.x, mid.y);
    } else if (pos == BG_IMAGE_MR) {
        dest_offset = float2(end.x, mid.y);
    } else if (pos == BG_IMAGE_BL) {
        dest_offset = float2(start.x, end.y);
    } else if (pos == BG_IMAGE_BC) {
        dest_offset = float2(mid.x, end.y);
    } else if (pos == BG_IMAGE_BR) {
        dest_offset = float2(end.x, end.y);
    }

    out_data.offset = dest_offset;
    out_data.scale = tex_size / dest_size;

    // We load a fully opaque version of the bg color and combine it with
    // the alpha separately, because we need these as separate values in
    // the fragment shader.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    out_data.bg_color = float4(
        load_color(uint4(u_bg_color.rgb, 255u), use_linear_blending).rgb,
        (float)u_bg_color.a / 255.0
    );

    return out_data;
}
