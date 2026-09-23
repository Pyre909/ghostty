#include "common.hlsl"

// The twin of glsl/image.f.glsl.
Texture2D<float4> image : register(t0);
// The render pass binds the default linear, clamping sampler here.
SamplerState image_sampler : register(s0);

struct VertexOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

float4 main(VertexOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image.Sample(image_sampler, in_data.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= rgba.a;

    return rgba;
}
