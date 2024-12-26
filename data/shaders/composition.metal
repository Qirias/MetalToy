#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half> drawingTexture, texture2d<half> distanceTexture, texture2d<half> lastTexture, rcParams rcData) {
    
    float2 coord = floor(uv * resolution);
    float partial = 0.0;
    
    float rayCount = pow(rcData.base, rcData.cascadeIndex + 1.0);
    float sqrtBase = sqrt(rcData.base);
    
    float oneOverRayCount = 1.0 / float(rayCount);
    float angleStepSize = TAU * oneOverRayCount;
    
    bool firstLevel = rcData.cascadeIndex == 0.0;
    
    float spacing = pow(sqrtBase, rcData.cascadeIndex);
    // Calculate the number of probes per x/y dimension
    float2 size = floor(resolution / spacing);
    // Calculate which probe we're processing this pass
    float2 probeRelativePosition = fmod(coord, size);
    // Calculate which group of rays we're processing this pass
    float2 rayPos = floor(coord / size);
    
    float2 probeCenter = (probeRelativePosition + 0.5) * spacing;
    float2 normalizedProbeCenter = probeCenter / resolution;
    
    float2 oneOverSize = 1.0 / resolution;
    float shortestSide = min(resolution.x, resolution.y);
    float2 scale = shortestSide * oneOverSize;
    
    // Hand-wavy rule that improved smoothing of other base ray counts
    float modifierHack = rcData.base < 16.0 ? 1.0 : 4.0;

    float intervalStart = firstLevel ? 0.0 : (modifierHack * pow(rcData.base, rcData.cascadeIndex - 1.0)) / shortestSide;
    float intervalLength = (modifierHack * pow(rcData.base, rcData.cascadeIndex)) / shortestSide;

    float baseIndex = float(rcData.base) * (rayPos.x + (spacing * rayPos.y));

    float minStepSize = min(oneOverSize.x, oneOverSize.y) * 0.5;
    
    half4 radiance = half4(0.0);
    
    for (int i = 0; i < int(rcData.base); i++) {
        float index = baseIndex + float(i);
        float angleStep = index + 0.5;
        float angle = angleStepSize * angleStep;
        float2 rayDirection = float2(cos(angle), -sin(angle));

        float2 sampleUV = normalizedProbeCenter + intervalStart * rayDirection * scale;
		half4 radDelta = half4(0.0);
        float traveled = 0.0;
        
        bool dontStart = outOfBounds(sampleUV);
        
        for (int step = 1; step < maxSteps && !dontStart; step++) {
            
			float dist = distanceTexture.sample(samplerNearest, sampleUV).x;
			
			sampleUV += rayDirection * dist * scale;
			
            if (outOfBounds(sampleUV)) break;
			
			if (dist <= minStepSize) {
                half4 colorSample = drawingTexture.sample(samplerNearest, sampleUV);
                radDelta += half4(half3(pow(colorSample.rgb, half3(2.2f))), colorSample.a);
				break;
			}
            traveled += dist;
            if (traveled >= intervalLength) break;
        }
        
        bool nonOpaque = radDelta.a == 0.0;
        
        if (rcData.cascadeIndex < rcData.cascadeCount - 1.0 && nonOpaque) {
            float upperSpacing = pow(sqrtBase, rcData.cascadeIndex + 1.0);
            // Grid of probes
            float2 upperSize = floor(resolution / upperSpacing);
            // Position of _this_ probe
            float2 upperPosition = float2(
                fmod(index, upperSpacing),
                floor(index / upperSpacing)
            ) * upperSize;
            
            float2 offset = (probeRelativePosition + 0.5) / sqrtBase;
            float2 clamped = clamp(offset, float2(0.5), upperSize - 0.5);
            float2 upperUV = (upperPosition + clamped) / resolution;
            
            radDelta += lastTexture.sample(samplerNearest, upperUV);
        }
        
		radiance += radDelta;
    }
    
	return radiance / float(rcData.base);
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
    
    bool isLastLayer = rcData.rayCount == rcData.base;
    
    half4 rayMarchedColor = rayMarch(uv, resolution, drawingTexture, distanceTexture, lastTexture, rcData);
    
    rayMarchedColor = (!isLastLayer ? rayMarchedColor : gammaCorrect(rayMarchedColor));
    
	return rayMarchedColor;
}
