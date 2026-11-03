#include <metal_stdlib>
using namespace metal;

struct Vertex { float3 position; float4 color; };
struct Raster { float4 position [[position]]; float4 color; };
vertex Raster p2_calibration_vertex(uint id [[vertex_id]],
    const device Vertex *vertices [[buffer(0)]], constant float4x4 &mvp [[buffer(1)]]) {
    return {mvp * float4(vertices[id].position, 1), vertices[id].color};
}
fragment float4 p2_calibration_fragment(Raster input [[stage_in]]) { return input.color; }
