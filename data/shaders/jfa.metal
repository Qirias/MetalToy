#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"


fragment half4 fragment_jfa(	VertexOut 		in 			[[stage_in]],
								texture2d<half> inputTex 	[[texture(TextureIndexDrawing)]],
					constant 	JFAParams& 		params 		[[buffer(BufferIndexJFAParams)]],
                    constant    FrameData&      frameData   [[buffer(BufferIndexFrameData)]]) {
	
    float2 uv = in.texCoords;
    uint2 resolution = uint2(frameData.width, frameData.height);

//	if (params.skip) {
//		return half4(uv.x, uv.y, 0.0, 1.0);
//	}

	float4 nearestSeed = float4(0.0);
	float nearestDist = FLT_MAX;

    for (float x = -1.0; x <= 1.0; x += 1.0) {
        for (float y = -1.0; y <= 1.0; y += 1.0) {
			float2 sampleUV = uv + float2(x, y) * params.uOffset * params.oneOverSize;

			if (outOfBounds(sampleUV)) {
                continue;
			}
            
            float4 sampleValue = float4(inputTex.sample(samplerNearest, sampleUV));
			float2 sampleSeed = float2(sampleValue.xy);
//            sampleSeed = floor(sampleSeed * float2(resolution));

			// If sample has a seed
			if (sampleSeed.x != 0.0 || sampleSeed.y != 0.0) {
                float2 diff = sampleSeed - uv;//floor(uv*float2(resolution));
				float dist = dot(diff, diff);

				if (dist < nearestDist) {
					nearestDist = dist;
					nearestSeed = sampleValue;
				}
			}
		}
	}

	return half4(nearestSeed);
}
