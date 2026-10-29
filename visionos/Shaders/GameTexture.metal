#include <metal_stdlib>
using namespace metal;
struct GameRaster { float4 position [[position]]; float2 uv; };
vertex GameRaster p2_game_vertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * 2 - 1, 0, 1), uv};
}
fragment float4 p2_game_fragment(GameRaster input [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    // The native GPU probe verifies IOSurface row 0 is GL's bottom row.
    return source.sample(sample, input.uv);
}
