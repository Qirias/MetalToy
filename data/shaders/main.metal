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
    out.position = float4(position * 2.0f - 1.0f, 0.0f, 1.0f);
	out.texCoords = float2(position.x, 1.0 - position.y);
    
    return out;
}
