#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half, access::read_write> drawingTexture) {
    half4 light = sampleTexture(drawingTexture, uv);
    
    if (light.a > 0.1) {
        return light;
    }
    
    float oneOverRayCount = 1.0 / float(rayCount);
    float tauOverRayCount = TAU * oneOverRayCount;
    
    float noise = rand(uv);
    
    half4 radiance = half4(0.0);
    
    for (int i = 0; i < rayCount; i++) {
        float angle = tauOverRayCount * (float(i) + noise);
        float2 rayDirectionUV = float2(cos(angle), -sin(angle)) / resolution;
        
        float2 sampleUV = uv + rayDirectionUV;
        
        for (int step = 0; step < maxSteps; step++) {
            if (outOfBounds(sampleUV)) break;
            
            half4 sampleLight = sampleTexture(drawingTexture, sampleUV);
            if (sampleLight.a > 0.5) {
                radiance += sampleLight;
                break;
            }
            
            sampleUV += rayDirectionUV;
        }
    }
    
    return radiance * oneOverRayCount;
}

kernel void compute_composition(    texture2d<half, access::read_write> outputTexture   [[texture(TextureIndexScreen)]],
                                    texture2d<half, access::read_write> drawingTexture  [[texture(TextureIndexDrawing)]],
                        constant    FrameData&                          frameData       [[buffer(BufferIndexFrameData)]],
                                    uint2                               gid             [[thread_position_in_grid]]) {

    uint width = drawingTexture.get_width();
    uint height = drawingTexture.get_height();

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(width, height);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(width, height);
    float2 uv = float2(gid) / float2(width, height);

    if (frameData.frameCount < 1) {
        outputTexture.write(half4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    if (frameData.mouseCoords.z <= 0.0f) {
        // Return the current color without modifying it (output the last drawn texture)
        return;
    }

    half4 drawingColor = sampleTexture(drawingTexture, uv);
    
    half4 rayMarchedColor = rayMarch(uv, float2(width, height), drawingTexture);
    
    rayMarchedColor = tonemap(rayMarchedColor);
    rayMarchedColor = gammaCorrect(rayMarchedColor);
    
    half4 finalColor = mix(drawingColor, rayMarchedColor, rayMarchedColor.a);

    // float alpha = sampleTexture(drawingTexture, uv).a;

    // outputTexture.write(half4(uv.x * alpha, uv.y * alpha, 0.0, 1.0), gid);
    outputTexture.write(finalColor, gid);
}