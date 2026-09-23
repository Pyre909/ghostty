#include "common.hlsl"

// Per-cell background colors; the twin of glsl/cell_bg.f.glsl.
//
// SV_Position has its origin in the upper left with pixel centers at +0.5,
// the same frame as the GLSL twin's `origin_upper_left` gl_FragCoord.

// One packed RGBA color per cell, row-major. Storage buffers follow the
// textures in the t registers: buffers[1] of the render step is t8.
StructuredBuffer<uint> cells : register(t8);

// One return rather than the GLSL's early returns: fxc warns about a
// possibly uninitialized result for those. A pixel in the padding that
// no edge extends into stays transparent.
float4 cell_bg(float2 frag_coord) {
    int2 grid_size = int2(unpack2u16(grid_size_packed_2u16));
    int2 grid_pos = int2(floor((frag_coord - grid_padding.wx) / cell_size));
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 bg = float4(0.0, 0.0, 0.0, 0.0);
    bool in_grid = true;

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            in_grid = false;
        }
    } else if (grid_pos.x > grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = grid_size.x - 1;
        } else {
            in_grid = false;
        }
    }

    // Clamp y position if we should extend, otherwise it stays out of bounds.
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            in_grid = false;
        }
    } else if (grid_pos.y > grid_size.y - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = grid_size.y - 1;
        } else {
            in_grid = false;
        }
    }

    // Load the color for the cell.
    if (in_grid) {
        bg = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x]),
            use_linear_blending
        );
    }

    return bg;
}

float4 main(float4 position : SV_Position) : SV_Target {
    return cell_bg(position.xy);
}
