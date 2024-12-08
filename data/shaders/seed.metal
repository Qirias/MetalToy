#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"


fragment half4 fragment_seed(VertexOut 			in 			[[stage_in]],
							 texture2d<half> 	drawing 	[[texture(TextureIndexDrawing)]],
                 constant    FrameData&         frameData   [[buffer(BufferIndexFrameData)]]) {

	float2 uv = in.texCoords;
    uint2 resolution = uint2(frameData.width, frameData.height);

    float alpha = drawing.sample(samplerLinear, uv).a;
	return half4(uv.x*alpha, uv.y*alpha, 0.0, 1.0);
}
