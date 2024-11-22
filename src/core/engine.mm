#include "engine.hpp"

Engine::Engine()
: camera(simd::float3{0.0f, 0.0f, 3.0f}, 0.1, 1000)
, lastFrame(0.0f)
, frameNumber(0)
, currentFrameIndex(0) {
	inFlightSemaphore = dispatch_semaphore_create(MaxFramesInFlight);

    for (int i = 0; i < MaxFramesInFlight; i++) {
        frameSemaphores[i] = dispatch_semaphore_create(1);
    }
}

void Engine::init() {
    initDevice();
    initWindow();

    createCommandQueue();
    createBuffers();
    createDefaultLibrary();
    createRenderPipelines();
	createRenderPassDescriptor();
}

void Engine::run() {
    while (!glfwWindowShouldClose(glfwWindow)) {
        float currentFrame = glfwGetTime();
        float deltaTime = currentFrame - lastFrame;
        lastFrame = currentFrame;
        
        camera.processKeyboardInput(glfwWindow, deltaTime);
        
        @autoreleasepool {
            metalDrawable = (__bridge CA::MetalDrawable*)[metalLayer nextDrawable];
            draw();
        }
        
        glfwPollEvents();
    }
}

void Engine::cleanup() {
    glfwTerminate();
	
	for(uint8_t i = 0; i < MaxFramesInFlight; i++) {
		frameDataBuffers[i]->release();
    }
	
	renderPassDescriptor->release();
    pipelineState->release();
    metalDevice->release();
}

void Engine::initDevice() {
    metalDevice = MTL::CreateSystemDefaultDevice();
}

void Engine::frameBufferSizeCallback(GLFWwindow *window, int width, int height) {
    Engine* engine = (Engine*)glfwGetWindowUserPointer(window);
    engine->resizeFrameBuffer(width, height);
}

void Engine::mouseButtonCallback(GLFWwindow* window, int button, int action, int mods) {
    Engine* engine = (Engine*)glfwGetWindowUserPointer(window);
    engine->camera.processMouseButton(window, button, action);
}

void Engine::cursorPosCallback(GLFWwindow* window, double xpos, double ypos) {
    Engine* engine = (Engine*)glfwGetWindowUserPointer(window);
    engine->camera.processMouseMovement(xpos, ypos);
}

void Engine::resizeFrameBuffer(int width, int height) {
    metalLayer.drawableSize = CGSizeMake(width, height);
    // Deallocate the textures if they have been created
	if (screenTexture) {
		screenTexture->release();
		screenTexture = nullptr;
	}
	
	// Recreate G-buffer textures and descriptors
	createRenderPassDescriptor();
    metalDrawable = (__bridge CA::MetalDrawable*)[metalLayer nextDrawable];
    updateRenderPassDescriptor();
}

void Engine::initWindow() {
    glfwInit();
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindow = glfwCreateWindow(800, 600, "MetalToy", NULL, NULL);
    if (!glfwWindow) {
        glfwTerminate();
        exit(EXIT_FAILURE);
    }

    int width, height;
    glfwGetFramebufferSize(glfwWindow, &width, &height);

    metalWindow = glfwGetCocoaWindow(glfwWindow);
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = (__bridge id<MTLDevice>)metalDevice;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.drawableSize = CGSizeMake(width, height);
    metalWindow.contentView.layer = metalLayer;
    metalWindow.contentView.wantsLayer = YES;

    glfwSetWindowUserPointer(glfwWindow, this);
    glfwSetFramebufferSizeCallback(glfwWindow, frameBufferSizeCallback);
    glfwSetMouseButtonCallback(glfwWindow, mouseButtonCallback);
    glfwSetCursorPosCallback(glfwWindow, cursorPosCallback);
    lastFrame = glfwGetTime();
    
    metalDrawable = (__bridge CA::MetalDrawable*)[metalLayer nextDrawable];
}

MTL::CommandBuffer* Engine::beginFrame(bool isPaused) {
	
    // Wait on the semaphore for the current frame
    dispatch_semaphore_wait(frameSemaphores[currentFrameIndex], DISPATCH_TIME_FOREVER);

    // Create a new command buffer for each render pass to the current drawable
    MTL::CommandBuffer* commandBuffer = metalCommandQueue->commandBuffer();

    updateWorldState(isPaused);
	
	return commandBuffer;
}

/// Perform operations necessary to obtain a command buffer for rendering to the drawable. By
/// endoding commands that are not dependant on the drawable in a separate command buffer, Metal
/// can begin executing encoded commands for the frame (commands from the previous command buffer)
/// before a drawable for this frame becomes available.
MTL::CommandBuffer* Engine::beginDrawableCommands() {
	MTL::CommandBuffer* commandBuffer = metalCommandQueue->commandBuffer();
	
	MTL::CommandBufferHandler handler = [this](MTL::CommandBuffer*) {
		// Signal the semaphore for this frame when GPU work is complete
		dispatch_semaphore_signal(frameSemaphores[currentFrameIndex]);
	};
	commandBuffer->addCompletedHandler(handler);
	
	return commandBuffer;
}

void Engine::endFrame(MTL::CommandBuffer* commandBuffer, MTL::Drawable* currentDrawable) {
    if(commandBuffer) {
        commandBuffer->presentDrawable(metalDrawable);
        commandBuffer->commit();
        
        // Move to next frame
        currentFrameIndex = (currentFrameIndex + 1) % MaxFramesInFlight;
    }
}

void Engine::createBuffers() {
    
}

void Engine::createDefaultLibrary() {
    // Create an NSString from the metallib path
    NS::String* libraryPath = NS::String::string(
        SHADER_METALLIB,
        NS::UTF8StringEncoding
    );
    
    NS::Error* error = nullptr;

    printf("Selected Device: %s\n", metalDevice->name()->utf8String());

    for(uint8_t i = 0; i < MaxFramesInFlight; i++) {
        frameDataBuffers[i] = metalDevice->newBuffer(sizeof(FrameData), MTL::ResourceStorageModeShared);
        frameDataBuffers[i]->setLabel(NS::String::string("FrameData", NS::ASCIIStringEncoding));
    }
    
    metalDefaultLibrary = metalDevice->newLibrary(libraryPath, &error);
    
    if (!metalDefaultLibrary) {
        std::cerr << "Failed to load metal library at path: " << SHADER_METALLIB;
        if (error) {
            std::cerr << "\nError: " << error->localizedDescription()->utf8String();
        }
        std::exit(-1);
    }
}

void Engine::updateWorldState(bool isPaused) {
	if (!isPaused) {
		frameNumber++;
	}

	FrameData *frameData = (FrameData *)(frameDataBuffers[currentFrameIndex]->contents());

	float aspectRatio = metalDrawable->layer()->drawableSize().width / metalDrawable->layer()->drawableSize().height;

	frameData->framebuffer_width = (uint)metalLayer.drawableSize.width;
	frameData->framebuffer_height = (uint)metalLayer.drawableSize.height;

	frameData->time = glfwGetTime();

    frameData->mouseCoords = simd::float2{(float)camera.getLastX(), (float)camera.getLastY()};
	frameData->keyboardDigits = camera.getKeys().digits;
    
}


void Engine::createCommandQueue() {
    metalCommandQueue = metalDevice->newCommandQueue();
}

void Engine::createRenderPipelines() {
    NS::Error* error = nullptr;

    #pragma mark full-screen triangle render pipeline setup
    {
        MTL::Function* vertexFunction = metalDefaultLibrary->newFunction(NS::String::string("vertex_function", NS::ASCIIStringEncoding));
        MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_function", NS::ASCIIStringEncoding));

        assert(vertexFunction && "Failed to load the vertex function!");
		assert(fragmentFunction && "Failed to load the fragmentFunction function!");
		

        MTL::RenderPipelineDescriptor* pipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		pipelineDescriptor->setLabel(NS::String::string("Full-Screen Triangle Creation", NS::ASCIIStringEncoding));

        pipelineDescriptor->setVertexFunction(vertexFunction);
        pipelineDescriptor->setFragmentFunction(fragmentFunction);
        pipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatBGRA8Unorm);
        
        pipelineState = metalDevice->newRenderPipelineState(pipelineDescriptor, &error);
        
		assert(error == nil && "Failed to create full-screen triangle render pipeline state!");

		pipelineDescriptor->release();
		vertexFunction->release();
		fragmentFunction->release();
    }

    #pragma mark compute pipeline setup
    {
        MTL::Function* computeFunction = metalDefaultLibrary->newFunction(NS::String::string("compute_function", NS::ASCIIStringEncoding));
        assert(computeFunction && "Failed to load compute function!");

        computePipelineState = metalDevice->newComputePipelineState(computeFunction, &error);
        assert(error == nil && "Failed to create compute pipeline state!");

        computeFunction->release();
    }
}

void Engine::createRenderPassDescriptor() {
    renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
    
    MTL::RenderPassColorAttachmentDescriptor* colorAttachment = renderPassDescriptor->colorAttachments()->object(0);
    colorAttachment->setLoadAction(MTL::LoadActionClear);
    colorAttachment->setStoreAction(MTL::StoreActionStore);
    colorAttachment->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));

    MTL::SamplerDescriptor* samplerDescriptor = MTL::SamplerDescriptor::alloc()->init();
    samplerDescriptor->setMinFilter(MTL::SamplerMinMagFilterLinear);
    samplerDescriptor->setMagFilter(MTL::SamplerMinMagFilterLinear);
    samplerDescriptor->setMipFilter(MTL::SamplerMipFilterLinear);
    samplerDescriptor->setSAddressMode(MTL::SamplerAddressModeClampToEdge);
    samplerDescriptor->setTAddressMode(MTL::SamplerAddressModeClampToEdge);
    samplerState = metalDevice->newSamplerState(samplerDescriptor);

    MTL::TextureDescriptor* textureDesc = MTL::TextureDescriptor::texture2DDescriptor(
        MTL::PixelFormatRGBA8Unorm,
        metalLayer.drawableSize.width,
        metalLayer.drawableSize.height,
        false
    );
    textureDesc->setUsage(MTL::TextureUsageShaderWrite | MTL::TextureUsageShaderRead);
    textureDesc->setStorageMode(MTL::StorageModePrivate);  // GPU-only access
    screenTexture = metalDevice->newTexture(textureDesc);
}

void Engine::updateRenderPassDescriptor() {
    if (!renderPassDescriptor) {
        createRenderPassDescriptor();
    }

    // Update the drawable texture for rendering
    renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());
}

void Engine::performComputePass(MTL::ComputeCommandEncoder* computeEncoder) {
    computeEncoder->pushDebugGroup(NS::String::string("Compute Pass", NS::ASCIIStringEncoding));
    computeEncoder->setComputePipelineState(computePipelineState);
    
    // Set the output texture that will be used by the render pass
    computeEncoder->setTexture(screenTexture, 0);
    computeEncoder->setBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    
    // Calculate dispatch size
    MTL::Size threadGroupSize = MTL::Size(16, 16, 1);
    MTL::Size gridSize = MTL::Size(
        (screenTexture->width() + threadGroupSize.width - 1) / threadGroupSize.width,
        (screenTexture->height() + threadGroupSize.height - 1) / threadGroupSize.height,
        1
    );
    
    computeEncoder->dispatchThreadgroups(gridSize, threadGroupSize);
    computeEncoder->popDebugGroup();
}

void Engine::drawTexture(MTL::RenderCommandEncoder* renderCommandEncoder) {
    renderCommandEncoder->pushDebugGroup(NS::String::string("Draw Frame", NS::ASCIIStringEncoding));
    renderCommandEncoder->setRenderPipelineState(pipelineState);
    renderCommandEncoder->setFragmentTexture(screenTexture, 0);  // Use compute shader output
    renderCommandEncoder->setFragmentSamplerState(samplerState, 0);
    renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
    renderCommandEncoder->popDebugGroup();
}

void Engine::draw() {
    // Compute pass
    MTL::CommandBuffer* computeCommandBuffer = beginFrame(false);
    if (computeCommandBuffer) {
        MTL::ComputeCommandEncoder* computeEncoder = computeCommandBuffer->computeCommandEncoder();
        if (computeEncoder) {
            performComputePass(computeEncoder);
            computeEncoder->endEncoding();
        }
        computeCommandBuffer->commit();  // Start compute work immediately
    }
    
    // Rendering texture
    MTL::CommandBuffer* renderCommandBuffer = beginDrawableCommands();
    updateRenderPassDescriptor();
    
    MTL::RenderCommandEncoder* renderEncoder = renderCommandBuffer->renderCommandEncoder(renderPassDescriptor);
    if (renderEncoder) {
        drawTexture(renderEncoder);
        renderEncoder->endEncoding();
    }
    
    endFrame(renderCommandBuffer, metalDrawable);
}