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

// The source projection is the symmetric frustum the engine rendered with,
// covering this eye's asymmetric compositor view. z = 0 is the reverse-Z far
// plane; both projections share the eye origin, so only the ray matters.
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

// Sense controller aiming laser, drawn over the (depthless) game image. All
// geometry is built in eye space: a beam quad turned toward the eye, then a
// round end dot facing the eye. Layout matches PortalRenderer.LaserUniforms.
struct LaserUniforms {
    float4x4 projection;     // clip from eye (rightUpBack, reverse Z)
    float4x4 eyeFromOrigin;  // inverse(originFromHead * headFromEye)
    float4 start, end;       // ARKit origin space, w = 1
    float4 color;            // rgb, a: beam alpha
    float halfWidth, dotRadius;
    float2 padding;
};
struct LaserRaster { float4 position [[position]]; float2 uv; float isDot [[flat]]; };
vertex LaserRaster p2_laser_vertex(uint id [[vertex_id]], constant LaserUniforms &u [[buffer(1)]]) {
    const float2 corners[6] = {{-1,0},{1,0},{1,1},{-1,0},{1,1},{-1,1}};
    float3 a = (u.eyeFromOrigin * u.start).xyz, b = (u.eyeFromOrigin * u.end).xyz;
    float2 c = corners[id % 6];
    float3 p;
    if (id < 6) {
        p = mix(a, b, c.y);
        float3 side = cross(b - a, p);  // across the beam, perpendicular to the view ray
        float length2 = dot(side, side);
        side = length2 > 1e-12 ? side * rsqrt(length2) : float3(1, 0, 0);
        p += side * (c.x * u.halfWidth);
    } else {
        c.y = c.y * 2 - 1;
        p = b + float3(c * u.dotRadius, 0);
    }
    return {u.projection * float4(p, 1), c, id < 6 ? 0.0 : 1.0};
}
fragment float4 p2_laser_fragment(LaserRaster in [[stage_in]], constant LaserUniforms &u [[buffer(1)]]) {
    if (in.isDot < 0.5) {
        float across = 1 - abs(in.uv.x);
        return float4(u.color.rgb, u.color.a * across * (1 - 0.6 * in.uv.y));
    }
    float r = length(in.uv);
    if (r > 1) discard_fragment();
    return float4(u.color.rgb, min(1.0, u.color.a * 1.8) * (1 - smoothstep(0.55, 1.0, r)));
}
