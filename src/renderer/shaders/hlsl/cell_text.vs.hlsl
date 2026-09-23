#include "common.hlsl"

// One instanced quad per glyph; the twin of glsl/cell_text.v.glsl.
//
// The instance layout is the CellText struct in d3d11/shaders.zig; the
// semantic names match its input element table. The atlas index and the
// glyph bools travel as one two-byte element (x = atlas, y = bools) so that
// every element offset is a multiple of four.

struct VertexIn {
    // The position of the glyph in the texture (x, y)
    uint2 glyph_pos : GLYPH_POS;
    // The size of the glyph in the texture (w, h)
    uint2 glyph_size : GLYPH_SIZE;
    // The left and top bearings for the glyph (x, y)
    int2 bearings : BEARINGS;
    // The grid coordinates (x, y) where x < columns and y < rows
    uint2 grid_pos : GRID_POS;
    // The color of the rendered text glyph.
    uint4 color : COLOR;
    // Which atlas this glyph is in, and misc glyph properties.
    uint2 atlas_bools : ATLAS_BOOLS;
    uint vid : SV_VertexID;
};

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

// Masks for the `glyph_bools` attribute
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

// One packed RGBA color per cell, row-major: buffers[1] of the step.
StructuredBuffer<uint> bg_colors : register(t8);

VertexOut main(VertexIn in_data) {
    VertexOut out_data;

    uint atlas = in_data.atlas_bools.x;
    uint glyph_bools = in_data.atlas_bools.y;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Convert the grid x, y into world space x, y by accounting for cell size
    float2 cell_pos = cell_size * float2(in_data.grid_pos);

    uint vid = in_data.vid;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    float2 corner;
    corner.x = (float)(vid == 1 || vid == 3);
    corner.y = (float)(vid == 2 || vid == 3);

    out_data.atlas = atlas;

    //              === Grid Cell ===
    //      +X
    // 0,0--...->
    //   |
    //   . offset.x = bearings.x
    // +Y.               .|.
    //   .               | |
    //   |   cell_pos -> +-------+   _.
    //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
    //                 | | .###. | |
    //                 | | #...# | |
    //   glyph_size.y -+ | ##### | |
    //                 | | #.... | +- bearings.y
    //                 |_| .#### | |
    //                   |       |_|
    //                   +-------+
    //                     |_._|
    //                       |
    //                  glyph_size.x
    //
    // In order to get the top left of the glyph, we compute an offset based on
    // the bearings. The Y bearing is the distance from the bottom of the cell
    // to the top of the glyph, so we subtract it from the cell height to get
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.

    float2 size = float2(in_data.glyph_size);
    float2 offset = float2(in_data.bearings);

    offset.y = cell_size.y - offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    out_data.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture will
    // be read by pixel coordinate.
    out_data.tex_coord = float2(in_data.glyph_pos) + float2(in_data.glyph_size) * corner;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    out_data.color = load_color(in_data.color, true);
    // Get the BG color
    out_data.bg_color = load_color(
        unpack4u8(bg_colors[in_data.grid_pos.y * grid_size.x + in_data.grid_pos.x]),
        true
    );
    // Blend it with the global bg color
    float4 global_bg = load_color(
        unpack4u8(bg_color_packed_4u8),
        true
    );
    out_data.bg_color += global_bg * (1.0 - out_data.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    if (min_contrast > 1.0f && (glyph_bools & NO_MIN_CONTRAST) == 0) {
        // Ensure our minimum contrast
        out_data.color = contrasted_color(min_contrast, out_data.color, out_data.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((in_data.grid_pos.x == cursor_pos.x) || (cursor_wide && (in_data.grid_pos.x == (cursor_pos.x + 1)))) && (in_data.grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, but we're not processing
    // the cursor glyph itself, then we need to change the color.
    if ((glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        out_data.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return out_data;
}
