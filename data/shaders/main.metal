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
                                        
    half4 texColor = screenTexture.sample(samplerState, in.texCoords);
    return texColor;
}

// Constants
constant float PI = 3.14159265;
constant float TAU = 2.0 * PI;
constant int rayCount = 4;
constant int maxSteps = 256;

constant half4 colors[5] = {
    half4(1.0, 0.0, 0.0, 1.0), // Red for digit '1'
    half4(0.0, 1.0, 0.0, 1.0), // Green for digit '2'
    half4(0.0, 0.0, 1.0, 1.0), // Blue for digit '3'
    half4(1.0, 1.0, 0.0, 1.0), // Yellow for digit '4'
    half4(1.0, 0.0, 1.0, 1.0)  // Magenta for digit '5'
};

float rand(float2 co) {
    return fract(sin(dot(co.xy ,float2(12.9898,78.233))) * 43758.5453);
}

static bool outOfBounds(float2 uv) {
    return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

half4 tonemap(half4 color) {
    return color / (color + half4(1.0));
}

half4 gammaCorrect(half4 color) {
    return half4(pow(color.xyz, half3(1.0 / 2.2)), color.w);
}

// Helper function to convert UV to pixel coordinates and sample texture
half4 sampleTexture(texture2d<half, access::read_write> tex, float2 uv) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    uint2 pixelCoord = uint2(uv * texSize);
    
    if (pixelCoord.x >= tex.get_width() || pixelCoord.y >= tex.get_height() 
        || pixelCoord.x < 0 || pixelCoord.y < 0) {
        return half4(0.0);
    }
    
    return tex.read(pixelCoord);
}

static half4 draw(float2 uv
                , float2 normalizedCurrMouse
                , float2 normalizedPrevMouse
                , float mousePressed
                , float prevPressed
                , half4 currentColor
                , uint digits) {
    float4 iMouse = float4(normalizedCurrMouse.x, normalizedCurrMouse.y, mousePressed, prevPressed);
    
    float2 prevMouse = iMouse.w > 0.0 ? normalizedPrevMouse : iMouse.xy;
    float2 currMouse = iMouse.xy;
    
    float lineL = length(currMouse - prevMouse);
    float lineW = 0.025f;
    half4 col = currentColor;

    half4 trailColor = colors[0];

    // If any of the digits 1-5 are pressed, select the corresponding color
    for (int i = 0; i <= 5; ++i) {
        if (digits & (1 << i)) {
            trailColor = colors[i];
            break;
        }
    }
    
    if (iMouse.z > 0.0f && lineL > 0.0f) {
        for (float d = 0.0; d < lineL; d+=0.01) {
            float press = 0.5;
            float2 samplePos = mix(prevMouse, currMouse, d/lineL);
            
            col += half4(smoothstep(lineW*press, 0.0f, length(samplePos - uv)) * trailColor);
        }
    }
    
    return col;
}

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
        
        // Our current position, plus one step
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

kernel void compute_function(   texture2d<half, access::read_write> outputTexture   [[texture(0)]],
                                texture2d<half, access::read_write> drawingTexture  [[texture(1)]],
                    constant    FrameData&                          frameData       [[buffer(BufferIndexFrameData)]],
                                uint2                               gid             [[thread_position_in_grid]]) {

    uint width = drawingTexture.get_width();
    uint height = drawingTexture.get_height();

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(width, height);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(width, height);
    float2 uv = float2(gid) / float2(width, height);

    if (frameData.frameCount < 1) {
        outputTexture.write(half4(0.0, 0.0, 0.0, 0.0), gid);
        drawingTexture.write(half4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    // if (frameData.mouseCoords.z <= 0.0f) {
    //     // Return the current color without modifying it (present the last drawn texture)
    //     return;
    // }
    
    half4 currentColor = drawingTexture.read(gid);

    half4 newColor = draw(uv, normalizedCurrMouse, normalizedPrevMouse, 
                          frameData.mouseCoords.z, frameData.mouseCoords.w, 
                          currentColor, frameData.keyboardDigits);
    drawingTexture.write(newColor, gid);
    

    half4 rayMarchedColor = rayMarch(uv, float2(width, height), drawingTexture);
    
    rayMarchedColor = tonemap(rayMarchedColor);
    rayMarchedColor = gammaCorrect(rayMarchedColor);
    
    half4 finalColor = mix(newColor, rayMarchedColor, rayMarchedColor.a);

    outputTexture.write(finalColor, gid);
}