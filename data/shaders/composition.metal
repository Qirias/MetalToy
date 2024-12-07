#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half> drawingTexture, texture2d<half> distanceTexture, texture2d<half> lastTexture, float2 effectiveUV, rcParams rcData) {
    half4 light = drawingTexture.sample(samplerNearest, uv);
    
    float partial = 0.125;
    float intervalStart = rcData.rayCount == rcData.baseRayCount ? 0.0 : partial;
    float intervalEnd = rcData.rayCount == rcData.baseRayCount ? partial : sqrt(2.0);
    
    if (light.a > 0.1) {
        return light;
    }
    
    float oneOverRayCount = 1.0 / float(rcData.rayCount);
    float tauOverRayCount = TAU * oneOverRayCount;
    
//    float noise = rand(uv);
    float2 oneOverSize = float2(1.0 / resolution);
    float2 scale = min(resolution.x, resolution.y) * oneOverSize;
    float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;
    
    half4 radiance = half4(0.0);
    
    for (int i = 0; i < rcData.rayCount; i++) {
        float index = float(i);
        float angleStep = index + 0.5;
        float angle = tauOverRayCount * angleStep;
        
        float2 rayDirection = float2(cos(angle), -sin(angle));

        float2 sampleUV = effectiveUV + rayDirection * intervalStart * scale;
		half4 radDelta = half4(0.0);
        float traveled = intervalStart;
        
        for (int step = 1; step < maxSteps; step++) {
            
			float dist = distanceTexture.sample(samplerNearest, sampleUV).x;
			
			sampleUV += rayDirection * dist * scale;
			
            if (outOfBounds(sampleUV)) break;
			
			if (dist < minStepSize) {
				radDelta += drawingTexture.sample(samplerNearest, sampleUV);
				break;
			}
            traveled += dist;
            if (traveled >= intervalEnd) break;
        }
        
        if (rcData.rayCount == rcData.baseRayCount && radDelta.a == 0.0) {
            half4 upperSample = lastTexture.sample(samplerNearest, uv);
            radDelta += half4(upperSample.rgb, upperSample.a);
        }
        
		radiance += radDelta;
    }
    
	return radiance * oneOverRayCount;
}

fragment half4 fragment_composition(	VertexOut 			in 				[[stage_in]],
										texture2d<half> 	distanceTexture [[texture(TextureIndexDistance)]],
										texture2d<half> 	drawingTexture  [[texture(TextureIndexDrawing)]],
                                        texture2d<half>     lastTexture     [[texture(TextureIndexLast)]],
							constant 	FrameData&          frameData       [[buffer(BufferIndexFrameData)]],
                            constant    rcParams&           rcData          [[buffer(BufferIndexRCParams)]]) {

    float2 resolution = float2(frameData.width, frameData.height);
    float2 uv = in.texCoords;
    float2 coord = floor(uv * resolution);
    
    bool isLastLayer = rcData.rayCount == rcData.baseRayCount;
    
    float2 effectiveUV = isLastLayer ? uv : (floor(coord / 2.0) * 2.0) / resolution;
    
    half4 rayMarchedColor = rayMarch(uv, resolution, drawingTexture, distanceTexture, lastTexture, effectiveUV, rcData);
    
    rayMarchedColor = gammaCorrect(rayMarchedColor);

	return rayMarchedColor;
}
