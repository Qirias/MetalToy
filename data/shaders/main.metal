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
                                    texture2d<half> screenTexture   [[texture(TextureIndexScreen)]],
                                    sampler         samplerState    [[sampler(0)]]) {
                                        
    half4 texColor = screenTexture.sample(samplerState, in.texCoords);
    return texColor;
}