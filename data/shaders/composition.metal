#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half> drawingTexture, texture2d<half> distanceTexture, texture2d<half> lastTexture, float2 effectiveUV, rcParams rcData) {
    half4 light = drawingTexture.sample(samplerNearest, uv);
    
    float partial = 0.0;
    
    float sqrtBase = sqrt(float(rcData.baseRayCount));
    float oneOverRayCount = 1.0 / float(rcData.rayCount);
    float angleStepSize = TAU / float(rcData.rayCount);
    float2 coord = floor(uv * resolution);
    bool firstLevel = rcData.rayCount == rcData.baseRayCount;
    
    float spacing = firstLevel ? 1.0 : sqrtBase;
    // Calculate the number of probes per x/y dimension
    float2 size = floor(resolution / spacing);
    // Calculate which probe we're processing this pass
    float2 probeRelativePosition = fmod(coord, size);
    // Calculate which group of rays we're processing this pass
    float2 rayPos = floor(coord / size);
    
    float intervalStart = firstLevel ? 0.0 : partial;
    float intervalEnd = firstLevel ? partial : sqrt(2.0);
    
    float2 probeCenter = (probeRelativePosition + 0.5) * spacing;
    float2 normalizedProbeCenter = probeCenter / resolution;
    
    float baseIndex = float(rcData.baseRayCount) * (rayPos.x + (spacing * rayPos.y));
    
    float2 oneOverSize = float2(1.0 / resolution);
    float2 scale = min(resolution.x, resolution.y) * oneOverSize;

    
    float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;
    
    
    half4 radiance = half4(0.0);
    
    for (int i = 0; i < int(rcData.rayCount); i++) {
        float index = baseIndex + float(i);
        float angleStep = index + 0.5;
        float angle = angleStepSize * angleStep;
        float2 rayDirection = float2(cos(angle), -sin(angle));

        float2 sampleUV = normalizedProbeCenter + rayDirection * intervalStart * scale;
		half4 radDelta = half4(0.0);
        float traveled = intervalStart;
        
        for (int step = 1; step < maxSteps; step++) {
            
			float dist = distanceTexture.sample(samplerNearest, sampleUV).x;
			
			sampleUV += rayDirection * dist * scale;
			
            if (outOfBounds(sampleUV)) break;
			
			if (dist <= minStepSize) {
				radDelta += gammaCorrect(drawingTexture.sample(samplerNearest, sampleUV));
				break;
			}
            traveled += dist;
            if (traveled >= intervalEnd) break;
        }
        
        bool nonOpaque = radDelta.a == 0.0;
        
        if (firstLevel && nonOpaque) {
            float2 upperSpacing = sqrtBase;
            // Grid of probes
            float2 upperSize = floor(resolution / upperSpacing);
            // Position of _this_ probe
            float2 upperPosition = (fmod(index, sqrtBase), floor(index / upperSpacing)) * upperSize;
            
            float2 offset = (probeRelativePosition + 0.5) / upperSpacing;
            float2 upperUv = (upperPosition + offset) / resolution;
            
            radDelta += lastTexture.sample(samplerNearest, upperUv);
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
    
    rayMarchedColor = (rcData.lastIndex == 1.0 ? gammaCorrect(rayMarchedColor) : rayMarchedColor);

	return rayMarchedColor;
}
