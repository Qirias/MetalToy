#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"

struct VertexOut {
    float4 position [[position]];
    float2 texCoords;
};

vertex VertexOut vertex_function(   uint        vertexID   [[vertex_id]],
                        constant    FrameData&  frameData  [[buffer(BufferIndexFrameData)]]) {
    VertexOut out;
    
    // Generate full-screen triangle
    float2 position = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(position * 2.0f - 1.0f, 0.0f, 1.0f);
    out.texCoords = position;
    
    return out;
}

fragment half4 fragment_function(   VertexOut       in              [[stage_in]],
                        constant    FrameData&      frameData       [[buffer(BufferIndexFrameData)]],
                                    texture2d<half> screenTexture   [[texture(0)]],
                                    sampler         samplerState    [[sampler(0)]]) {
                                        
    // Simple texture sampling
    half4 texColor = screenTexture.sample(samplerState, in.texCoords);
    return texColor;
}

kernel void compute_function(   texture2d<half, access::write>  output      [[texture(0)]],
                    constant    FrameData&                      frameData   [[buffer(BufferIndexFrameData)]],
                                uint2                           gid         [[thread_position_in_grid]]) {

    uint width = output.get_width();
    uint height = output.get_height();
    
    float2 uv = float2(gid) / float2(width, height);
    uv = uv * 2.0 - 1.0;  // Normalize to [-1, 1]
    
    // Example: Procedural color based on UV and time
    half3 color = half3(uv.x + 0.5, uv.y + 0.5, sin(frameData.time));
    output.write(half4(color, 1.0), gid);
}