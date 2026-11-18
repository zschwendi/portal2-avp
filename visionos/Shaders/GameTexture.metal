#include <metal_stdlib>
using namespace metal;
struct GameRaster { float4 position [[position]]; float2 uv; };
vertex GameRaster p2_game_vertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * 2 - 1, 0, 1), uv};
}
fragment float4 p2_game_fragment(GameRaster input [[stage_in]], texture2d<float> source [[texture(0)]],
    texture2d<float> rightEye [[texture(1)]], constant uint2 &stereoFlags [[buffer(0)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    // The native GPU probe verifies IOSurface row 0 is GL's bottom row.
    // The engine's alpha channel is not window coverage.
    if (stereoFlags.x) {
        if (input.uv.x >= 0.5) return float4(rightEye.sample(sample, float2((input.uv.x - 0.5) * 2, input.uv.y)).rgb, 1);
        float y = stereoFlags.y ? 1 - input.uv.y : input.uv.y;
        return float4(source.sample(sample, float2(input.uv.x * 2, y)).rgb, 1);
    }
    return float4(source.sample(sample, input.uv).rgb, 1);
}

// Give the compositor a finite surface for the opaque color-only eye image.
vertex GameRaster p2_world_vertex(uint id [[vertex_id]], constant float &depth [[buffer(1)]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * 2 - 1, depth, 1), uv};
}

// The source projection is the symmetric frustum the engine rendered with,
// covering this eye's asymmetric compositor view. Use the far-plane ray for
// this RGB lookup independently of the depth submitted to the compositor.
fragment float4 p2_world_fragment(GameRaster input [[stage_in]], texture2d<float> source [[texture(0)]],
    constant float4x4 &sourceClipFromCurrentClip [[buffer(1)]]) {
    float4 clip = sourceClipFromCurrentClip * float4(input.uv * 2 - 1, 0, 1);
    float2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(uv < 0) || any(uv > 1)) return float4(0,0,0,1);
    constexpr sampler sample(filter::linear,address::clamp_to_edge);
    return float4(source.sample(sample, uv).rgb, 1);
}

vertex GameRaster p2_menu_vertex(uint id [[vertex_id]],constant float4x4 &mvp [[buffer(1)]]) {
    const float2 corners[6] = {{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}};
    float2 uv = corners[id];
    return {mvp * float4(uv * 2 - 1,0,1),uv};
}
fragment float4 p2_menu_fragment(GameRaster input [[stage_in]],texture2d<float> source [[texture(0)]]) {
    constexpr sampler sample(filter::linear,address::clamp_to_edge);
    return float4(source.sample(sample, input.uv).rgb, 1);
}
