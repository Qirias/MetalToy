#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

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
    for (int i = 0; i < 6; ++i) {
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

kernel void compute_drawing(    texture2d<half, access::read_write> drawingTexture  [[texture(TextureIndexDrawing)]],
                    constant    FrameData&                          frameData       [[buffer(BufferIndexFrameData)]],
                                uint2                               gid             [[thread_position_in_grid]]) {

    uint width = drawingTexture.get_width();
    uint height = drawingTexture.get_height();

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(width, height);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(width, height);
    float2 uv = float2(gid) / float2(width, height);

    if (frameData.frameCount < 1) {
        drawingTexture.write(half4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    if (frameData.mouseCoords.z <= 0.0f) {
        // Return the current color without modifying it (output the last drawn texture)
        return;
    }
    
    half4 currentColor = drawingTexture.read(gid);

    half4 newColor = draw(uv, normalizedCurrMouse, normalizedPrevMouse, 
                          frameData.mouseCoords.z, frameData.mouseCoords.w, 
                          currentColor, frameData.keyboardDigits);

    drawingTexture.write(newColor, gid);
}