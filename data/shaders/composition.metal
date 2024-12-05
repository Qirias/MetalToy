#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half> drawingTexture, texture2d<half> distanceTexture) {
    half4 light = drawingTexture.sample(samplerNearest, uv);
    
    if (light.a > 0.1) {
        return light;
    }
    
    float oneOverRayCount = 1.0 / float(rayCount);
    float tauOverRayCount = TAU * oneOverRayCount;
    
    float noise = rand(uv);
    
    half4 radiance = half4(0.0);
    
    for (int i = 0; i < rayCount; i++) {
        float angle = tauOverRayCount * (float(i) + noise);
        float2 rayDirection = float2(cos(angle), -sin(angle));

        float2 sampleUV = uv;
		half4 radDelta = half4(0.0);
        
        for (int step = 1; step < maxSteps; step++) {
            
			float dist = distanceTexture.sample(samplerNearest, sampleUV).x;
			
			sampleUV += rayDirection * dist;
			
            if (outOfBounds(sampleUV)) break;
			
			if (dist < EPS) {
				radDelta += drawingTexture.sample(samplerNearest, sampleUV);
				break;
			}
        }
		radiance += radDelta;
    }
    
	return radiance * oneOverRayCount;
}

fragment half4 fragment_composition(	VertexOut 			in 				[[stage_in]],
										texture2d<half> 	distanceTexture [[texture(TextureIndexDistance)]],
										texture2d<half> 	drawingTexture  [[texture(TextureIndexDrawing)]],
							constant 	FrameData&          frameData       [[buffer(BufferIndexFrameData)]]) {

    uint width = drawingTexture.get_width();
    uint height = drawingTexture.get_height();

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(width, height);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(width, height);
	float2 uv = in.texCoords;
    
    half4 rayMarchedColor = rayMarch(uv, float2(width, height), drawingTexture, distanceTexture);
    
    rayMarchedColor = gammaCorrect(rayMarchedColor);

//	rayMarchedColor = distanceTexture.sample(samplerNearest, uv);

	return rayMarchedColor;
}
