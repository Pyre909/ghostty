#include "common.hlsl"

// The surface background color over the whole target; the twin of
// glsl/bg_color.f.glsl.
float4 main() : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    return load_color(
        unpack4u8(bg_color_packed_4u8),
        use_linear_blending
    );
}
