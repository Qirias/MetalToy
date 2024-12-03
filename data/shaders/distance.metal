#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"


fragment half4 fragment_distance(	VertexOut 		in 			[[stage_in]],
									texture2d<half> jfaTexture 	[[texture(TextureIndexJFA)]],
                     constant       FrameData&      frameData   [[buffer(BufferIndexFrameData)]]) {
	
	float2 uv = in.texCoords;
    
	half4 nearestSeed = jfaTexture.sample(samplerNearest, uv);
//    if (nearestSeed.a < 0.1) return half4(1.0);
	float dist = clamp(distance(uv, float2(nearestSeed.xy)), 0.0, 1.0);

	return half4(dist, dist, dist, 1.0);
}
