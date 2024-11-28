#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

half4 rayMarch(float2 uv, float2 resolution, texture2d<half> drawingTexture) {
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
        float2 rayDirectionUV = float2(cos(angle), -sin(angle)) / resolution;
        
        float2 sampleUV = uv + rayDirectionUV;
        
        for (int step = 0; step < maxSteps; step++) {
            if (outOfBounds(sampleUV)) break;
            
            half4 sampleLight = drawingTexture.sample(samplerNearest, sampleUV);
            if (sampleLight.a > 0.5) {
                radiance += sampleLight;
                break;
            }
            
            sampleUV += rayDirectionUV;
        }
    }
    
    return radiance * oneOverRayCount;
}

fragment half4 fragment_composition(	VertexOut 			in 				[[stage_in]],
										texture2d<half> 	jfaTexture  	[[texture(TextureIndexJFA)]],
										texture2d<half> 	drawingTexture  [[texture(TextureIndexDrawing)]],
							constant 	FrameData&          frameData       [[buffer(BufferIndexFrameData)]]) {

    uint width = drawingTexture.get_width();
    uint height = drawingTexture.get_height();

    float2 normalizedCurrMouse = frameData.mouseCoords.xy / float2(width, height);
    float2 normalizedPrevMouse = frameData.prevMouse / float2(width, height);
	float2 uv = in.texCoords;

	half4 drawingColor = drawingTexture.sample(samplerNearest, uv);
    
    half4 rayMarchedColor = rayMarch(uv, float2(width, height), drawingTexture);
    
//    rayMarchedColor = tonemap(rayMarchedColor);
    rayMarchedColor = gammaCorrect(rayMarchedColor);
    
    half4 finalColor = mix(drawingColor, rayMarchedColor, rayMarchedColor.a);

	// float2 nearestSeed = float2(sampleTexture(jfaTexture, uv).xy);
	// // Clamp by the size of our texture (1.0 in uv space).
	// float dist = clamp(distance(uv, nearestSeed), 0.0, 1.0);
	// outputTexture.write(half4(dist, dist, dist, 1.0), gid);
//	finalColor = drawingTexture.sample(samplerNearest, uv);

	return finalColor;
}
