#include <simd/simd.h>

struct FrameData {
	uint framebuffer_width;                      // 4 bytes  (offset: 4)
	uint framebuffer_height;                     // 4 bytes  (offset: 8)
	float time;									 // 4 bytes  (offset: 12)
	float _padding;								 // 4 bytes  (offset: 16)
};

typedef enum BufferIndex
{
	BufferIndexFrameData = 0
} BufferIndex;
