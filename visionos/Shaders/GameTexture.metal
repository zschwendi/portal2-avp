#include <metal_stdlib>
using namespace metal;
struct GameRaster { float4 position [[position]]; float2 uv; };
vertex GameRaster p2_game_vertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * 2 - 1, 0, 1), uv};
}
fragment float4 p2_game_fragment(GameRaster input [[stage_in]], texture2d<float> source [[texture(0)]],
    texture2d<float> rightEye [[texture(1)]],constant uint &paired [[buffer(0)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    // The native GPU probe verifies IOSurface row 0 is GL's bottom row.
    if (paired) {
        if (input.uv.x >= 0.5) return rightEye.sample(sample,float2((input.uv.x-0.5)*2,input.uv.y));
        return source.sample(sample,float2(input.uv.x*2,input.uv.y));
    }
    return source.sample(sample, input.uv);
}

fragment float4 p2_world_fragment(GameRaster input [[stage_in]], texture2d<float> source [[texture(0)]],
    constant float4x4 &sourceClipFromCurrentClip [[buffer(1)]]) {
    float4 clip = sourceClipFromCurrentClip * float4(input.uv * 2 - 1, 0, 1);
    float2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(uv < 0) || any(uv > 1)) return float4(0,0,0,1);
    constexpr sampler sample(filter::linear,address::clamp_to_edge);
    return source.sample(sample,uv);
}

vertex GameRaster p2_menu_vertex(uint id [[vertex_id]],constant float4x4 &mvp [[buffer(1)]]) {
    const float2 corners[6] = {{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}};
    float2 uv = corners[id];
    return {mvp * float4(uv * 2 - 1,0,1),uv};
}
fragment float4 p2_menu_fragment(GameRaster input [[stage_in]],texture2d<float> source [[texture(0)]]) {
    constexpr sampler sample(filter::linear,address::clamp_to_edge);
    return source.sample(sample,input.uv);
}
