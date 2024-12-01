#pragma once

#include "pch.hpp"

#define GLFW_INCLUDE_NONE
#import <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#import <GLFW/glfw3native.h>

#include <Metal/Metal.hpp>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.hpp>
#include <QuartzCore/CAMetalLayer.h>
#include <QuartzCore/QuartzCore.hpp>


#include "vertexData.hpp"
#include "components/camera.hpp"
#include "../../data/shaders/shaderTypes.hpp"

#include <stb/stb_image.h>

#include <simd/simd.h>
#include <filesystem>

constexpr uint8_t MaxFramesInFlight = 3;
constexpr uint8_t MAXSTAGES = 12;


class Engine {
public:
    void init();
    void run();
    void cleanup();

	Engine();

private:
    void initDevice();
    void initWindow();

    void createBuffers();
	
	MTL::CommandBuffer* beginDrawableCommands(bool isPaused);
	void endFrame(MTL::CommandBuffer* commandBuffer, MTL::Drawable* currentDrawable);
    void updateWorldState(bool isPaused);
	
    void draw();
    void presentTexture(MTL::RenderCommandEncoder* renderCommandEncoder);

	void drawTexture(MTL::CommandBuffer* commandBuffer);
	void performJFA(MTL::CommandBuffer* commandBuffer);
	void performComposition(MTL::CommandBuffer* commandBuffer);

	void createRenderPassDescriptor();

    // resizing window
    void updateRenderPassDescriptor();

    void createDefaultLibrary();
    void createCommandQueue();
    void createRenderPipelines();

    void encodeRenderCommand(MTL::RenderCommandEncoder* renderCommandEncoder);
    void sendRenderCommand();

    static void frameBufferSizeCallback(GLFWwindow *window, int width, int height);
    void resizeFrameBuffer(int width, int height);
	
	dispatch_semaphore_t                                inFlightSemaphore;
    std::array<dispatch_semaphore_t, MaxFramesInFlight> frameSemaphores;
    uint8_t                                             currentFrameIndex;
	
	// Buffers used to store dynamically changing per-frame data
	MTL::Buffer* 							frameDataBuffers[MaxFramesInFlight];
	std::vector<std::vector<MTL::Buffer*>> 	jfaOffsetBuffer;

    MTL::Device*        metalDevice;
    GLFWwindow*         glfwWindow;
    NSWindow*           metalWindow;
    CAMetalLayer*       metalLayer;
    CA::MetalDrawable*  metalDrawable;
    
    bool                windowResizeFlag = false;
    int                 newWidth;
    int                 newHeight;

    float               lastFrame;
    
    static void mouseButtonCallback(GLFWwindow* window, int button, int action, int mods);
    static void cursorPosCallback(GLFWwindow* window, double xpos, double ypos);

    // Renderpass descriptors
    MTL::RenderPassDescriptor*  renderPassDescriptor;

    MTL::Texture*               drawingTexture;
    MTL::Texture*               jfaTexture;

    MTL::Library*               metalDefaultLibrary;
    MTL::CommandQueue*          metalCommandQueue;

	// Render Pipeline States
	MTL::RenderPipelineState*   drawingRenderPipelineState;
	MTL::RenderPipelineState*   jfaRenderPipelineState;
	MTL::RenderPipelineState*   compositionRenderPipelineState;

    MTL::SamplerState*          samplerState;

    Camera                      camera;

    uint64_t                    frameNumber;
    uint8_t                     frameDataBufferIndex;
	
	uint8_t						jfaPasses;
};
