#define METAL
#include <metal_stdlib>
using namespace metal;

constant half4 colors[6] = {
    half4(1.0, 0.0, 0.0, 1.0), // Red for digit '1'
    half4(0.0, 1.0, 0.0, 1.0), // Green for digit '2'
    half4(0.0, 0.0, 1.0, 1.0), // Blue for digit '3'
    half4(1.0, 1.0, 0.0, 1.0), // Yellow for digit '4'
    half4(1.0, 0.0, 1.0, 1.0), // Magenta for digit '5'
    half4(1.0, 1.0, 1.0, 1.0)  // White for digit '6'
};

static float rand(float2 co) {
    return fract(sin(dot(co.xy ,float2(12.9898,78.233))) * 43758.5453);
}

static bool outOfBounds(float2 uv) {
    return uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
}

static half4 tonemap(half4 color) {
    return color / (color + half4(1.0));
}

static half4 gammaCorrect(half4 color) {
    return half4(pow(color.xyz, half3(1.0 / 2.2)), color.w);
}

static half4 sampleTexture(texture2d<half, access::read_write> tex, float2 uv) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    uint2 pixelCoord = uint2(uv * texSize);
    
    if (pixelCoord.x >= tex.get_width() || pixelCoord.y >= tex.get_height() 
        || pixelCoord.x < 0 || pixelCoord.y < 0) {
        return half4(0.0);
    }
    
    return tex.read(pixelCoord);
}

// Constants
constant float PI = 3.14159265;
constant float TAU = 2.0 * PI;
constant int rayCount = 4;
constant int maxSteps = 256;