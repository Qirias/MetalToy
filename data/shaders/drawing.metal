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
    float lineW = 0.0125f;
    half4 col = currentColor;

    half4 trailColor = colors[0];

    // If any of the digits 1-7 are pressed, select the corresponding color
    for (int i = 0; i < 7; ++i) {
        if (digits & (1 << i)) {
            trailColor = colors[i];
            break;
        }
    }
    
    if (iMouse.z > 0.0f && lineL > 0.0f) {
        for (float d = 0.0; d < lineL; d+=0.01) {
            float2 samplePos = mix(prevMouse, currMouse, d/lineL);
            
            if (length(samplePos - uv) <= lineW) {
                col = trailColor;
            }
        }
    }
    
    return col;
}

fragment half4 fragment_drawing(	VertexOut 			in 				[[stage_in]],
									texture2d<half> 	drawingTexture  [[texture(TextureIndexDrawing)]],
						constant 	FrameData&          frameData       [[buffer(BufferIndexFrameData)]]) {

    uint2 resolution = uint2(frameData.width, frameData.height);

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(resolution);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(resolution);
	float2 uv = in.texCoords;

    if (frameData.frameCount < 1) {
        return half4(-1.0);
    }

    if (frameData.mouseCoords.z <= 0.0f) {
        // Return the current color without modifying it (output the last drawn texture)
        return drawingTexture.sample(samplerLinear, uv);
    }

    half4 currentColor = drawingTexture.sample(samplerLinear, uv);

    half4 newColor = draw(uv, normalizedCurrMouse, normalizedPrevMouse, 
                          frameData.mouseCoords.z, frameData.mouseCoords.w, 
                          currentColor, frameData.keyboardDigits);
	
	return newColor;
}
