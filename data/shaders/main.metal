#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

vertex VertexOut vertex_function(   uint        vertexID   [[vertex_id]],
                        constant    FrameData&  frameData  [[buffer(BufferIndexFrameData)]]) {
    VertexOut out;
    
    // Generate full-screen triangle
    float2 position = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(position * float2(2, -2) + float2(-1, 1), 0.0f, 1.0f);
    out.texCoords = position;
    
    return out;
}
