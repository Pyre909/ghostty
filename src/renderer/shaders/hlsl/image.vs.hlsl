#include "common.hlsl"

// One instanced quad per image placement; the twin of glsl/image.v.glsl.
// The instance layout is the Image struct in d3d11/shaders.zig.
Texture2D<float4> image : register(t0);

struct VertexIn {
    float2 grid_pos : GRID_POS;
    float2 cell_offset : CELL_OFFSET;
    float4 source_rect : SOURCE_RECT;
    float2 dest_size : DEST_SIZE;
    uint vid : SV_VertexID;
};

struct VertexOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

VertexOut main(VertexIn in_data) {
    VertexOut out_data;

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

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    float2 tex_coord = in_data.source_rect.xy;
    tex_coord += in_data.source_rect.zw * corner;

    // Normalize the coordinates.
    uint width, height;
    image.GetDimensions(width, height);
    tex_coord /= float2(width, height);
    out_data.tex_coord = tex_coord;

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    float2 image_pos = (cell_size * in_data.grid_pos) + in_data.cell_offset;
    image_pos += in_data.dest_size * corner;

    // z is 0 where the GLSL has 1: the projection negates z, and Direct3D
    // clips to 0 <= z <= w where OpenGL allows -w. Metal does the same.
    out_data.position = mul(projection_matrix, float4(image_pos.x, image_pos.y, 0.0f, 1.0f));

    return out_data;
}
