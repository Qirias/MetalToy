#define METAL
#include <metal_stdlib>
using namespace metal;

#include "shaderTypes.hpp"
#include "common.metal"

fragment half4 fragment_composition(	VertexOut 			in 				[[stage_in]],
										texture2d<half> 	drawingTexture  [[texture(TextureIndexDrawing)]],
							constant 	FrameData&          frameData       [[buffer(BufferIndexFrameData)]]) {

    float2 uv = in.texCoords;
    
    return  drawingTexture.sample(samplerNearest, uv);;
}
