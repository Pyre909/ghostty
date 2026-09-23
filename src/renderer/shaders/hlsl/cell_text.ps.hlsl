#include "common.hlsl"

// The twin of glsl/cell_text.f.glsl.
//
// The atlases are read by pixel coordinate with Load, which is the nearest
// sampling at pixel coordinates the other backends use.
Texture2D<float> atlas_grayscale : register(t0);
Texture2D<float4> atlas_color : register(t1);

struct VertexOut {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD0;
};

// Values `atlas` can take.
static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

float4 main(VertexOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    int3 texel = int3(int2(in_data.tex_coord), 0);

    if (in_data.atlas == ATLAS_COLOR) {
        // For now, we assume that color glyphs
        // are already premultiplied linear colors.
        float4 color = atlas_color.Load(texel);

        // If we are doing linear blending, we can return this right away.
        if (use_linear_blending) {
            return color;
        }

        // Otherwise we need to unlinearize the color. Since the alpha is
        // premultiplied, we need to divide it out before unlinearizing.
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;

        return color;
    }

    // ATLAS_GRAYSCALE, and anything unknown.

    // Our input color is always linear.
    float4 color = in_data.color;

    // If we're not doing linear blending, then we need to
    // re-apply the gamma encoding to our color manually.
    //
    // Since the alpha is premultiplied, we need to divide
    // it out before unlinearizing and re-multiply it after.
    if (!use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
    }

    // Fetch our alpha mask for this pixel.
    float a = atlas_grayscale.Load(texel);

    // Linear blending weight correction corrects the alpha value to
    // produce blending results which match gamma-incorrect blending.
    if (use_linear_correction) {
        // Short explanation of how this works:
        //
        // We get the luminances of the foreground and background colors,
        // and then unlinearize them and perform blending on them. This
        // gives us our desired luminance, which we derive our new alpha
        // value from by mapping the range [bg_l, fg_l] to [0, 1], since
        // our final blend will be a linear interpolation from bg to fg.
        //
        // This yields virtually identical results for grayscale blending,
        // and very similar but non-identical results for color blending.
        float4 bg = in_data.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        // To avoid numbers going haywire, we don't apply correction
        // when the bg and fg luminances are within 0.001 of each other.
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize_scalar(unlinearize_scalar(fg_l) * a + unlinearize_scalar(bg_l) * (1.0 - a));
            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
    }

    // Multiply our whole color by the alpha mask.
    // Since we use premultiplied alpha, this is
    // the correct way to apply the mask.
    color *= a;

    return color;
}
