// A single triangle that covers the whole viewport, from the vertex id
// alone; the twin of glsl/full_screen.v.glsl.
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
//
// Direct3D clips z to 0..w, so the depth sits in the middle of that range
// rather than at the far plane; no pass uses a depth buffer.
float4 main(uint vid : SV_VertexID) : SV_Position {
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 0.5;
    position.w = 1.0;
    return position;
}
