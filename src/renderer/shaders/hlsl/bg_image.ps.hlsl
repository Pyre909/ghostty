#include "common.hlsl"

// The twin of glsl/bg_image.f.glsl. SV_Position is the pixel position
// with its origin in the upper left, which is the orientation the GLSL
// asks for with origin_upper_left.
Texture2D<float4> image : register(t0);
// The render pass binds the default linear, clamping sampler here.
SamplerState image_sampler : register(s0);

struct VertexOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat : TEXCOORD3;
};

float4 main(VertexOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size, which effectively scales the original
    // size of the texture to the dest rect size.
    float2 tex_coord = (in_data.position.xy - in_data.offset) * in_data.scale;

    uint width, height;
    image.GetDimensions(width, height);
    float2 tex_size = float2(width, height);

    // If we need to repeat the texture, wrap the coordinates. fmod keeps
    // the sign of its dividend, which is why the inner result gets one
    // period added before the outer fmod brings it back into range.
    if (in_data.repeat != 0) {
        tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        rgba = image.Sample(image_sampler, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity, but cap it at
    // the value that will make it fully opaque relative to
    // the background color alpha, so it isn't overexposed.
    rgba *= min(in_data.opacity, 1.0 / in_data.bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(in_data.bg_color.rgb, 1.0) * (1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= in_data.bg_color.a;

    return rgba;
}
