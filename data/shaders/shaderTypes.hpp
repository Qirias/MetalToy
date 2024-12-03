#include <simd/simd.h>

struct FrameData {
	uint framebuffer_width;                     // 4 bytes  (offset: 4)
	uint framebuffer_height;                    // 4 bytes  (offset: 8)
	float time;									// 4 bytes  (offset: 12)
	uint keyboardDigits;   						// 4 bytes  (offset: 16)
	simd::float4 mouseCoords;                   // 16 bytes (offset: 32)
	float2 prevMouse;							// 8 bytes  (offset: 40)
	uint64_t frameCount;						// 8 bytes  (offset: 48)
};

struct JFAParams {
    float2 oneOverSize;
    float uOffset;
    int skip;
};

typedef enum BufferIndex {
	BufferIndexFrameData = 0,
	BufferIndexJFAParams = 1
} BufferIndex;

typedef enum TextureIndex {
	TextureIndexDrawing = 0,
	TextureIndexJFA = 1,
	TextureIndexDistance = 2,
	TextureIndexScreen = 3
} TextureIndex;
