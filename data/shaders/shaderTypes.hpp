#include <simd/simd.h>

struct FrameData {
	uint framebuffer_width;                     // 4 bytes  (offset: 4)
	uint framebuffer_height;                    // 4 bytes  (offset: 8)
	float time;									// 4 bytes  (offset: 12)
	uint keyboardDigits;   						// 4 bytes  (offset: 16)
	simd::float4 mouseCoords;                   // 16 bytes (offset: 32)
	float2 prevMouse;							// 8 bytes  (offset: 40)
	uint frameCount;							// 4 bytes  (offset: 44)
};

typedef enum BufferIndex {
	BufferIndexFrameData = 0
} BufferIndex;

typedef enum TextureIndex {
	TextureIndexDrawing = 0,
	TextudeIndexJFA = 1,
	TextureIndexScreen = 2
} TextureIndex;