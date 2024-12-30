#include "engine.hpp"

Engine::Engine()
: camera(simd::float3{0.0f, 0.0f, 3.0f}, 0.1, 1000)
, lastFrame(0.0f)
, frameNumber(0)
, currentFrameIndex(0)
, pixelFormat(MTL::PixelFormatRGBA8Unorm)
, jfaPasses(0)
, baseRayCount(16) {
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
            jfaPasses = ceil(log2(max(float(metalDrawable->layer()->drawableSize().width), float(metalDrawable->layer()->drawableSize().height))));
            draw();
        }
        
        glfwPollEvents();
    }
}

void Engine::cleanup() {
    glfwTerminate();
	
	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		frameDataBuffers[frame]->release();
        
        for(uint8_t stage = 0; stage < MAXSTAGES; stage++) {
            jfaOffsetBuffer[frame][stage]->release();
        }
        
        for(uint8_t cascade = 0; cascade < NUM_OF_CASCADES; cascade++) {
            rcBuffer[frame][cascade]->release();
        }
    }
	
	drawingTexture->release();
	seedTexture->release();
	jfaTexture->release();
	distanceTexture->release();
	renderPassDescriptor->release();
	drawingRenderPipelineState->release();
	seedRenderPipelineState->release();
	jfaRenderPipelineState->release();
	distanceRenderPipelineState->release();
	compositionRenderPipelineState->release();
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
	if (drawingTexture)     {   drawingTexture->release(); 	    drawingTexture = nullptr;   }
    if (jfaTexture)         {   jfaTexture->release(); 		    jfaTexture = nullptr;       }
    if (seedTexture)        {   seedTexture->release();         seedTexture = nullptr;      }
    if (distanceTexture)    {   distanceTexture->release();     distanceTexture = nullptr;  }
	
	createRenderPassDescriptor();
    metalDrawable = (__bridge CA::MetalDrawable*)[metalLayer nextDrawable];
    updateRenderPassDescriptor();
}

void Engine::initWindow() {
    glfwInit();
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindow = glfwCreateWindow(512, 512, "MetalToy", NULL, NULL);
    if (!glfwWindow) {
        glfwTerminate();
        exit(EXIT_FAILURE);
    }

    int width, height;
    glfwGetFramebufferSize(glfwWindow, &width, &height);

    metalWindow = glfwGetCocoaWindow(glfwWindow);
    metalLayer = [CAMetalLayer layer];
    metalLayer.device = (__bridge id<MTLDevice>)metalDevice;
    metalLayer.pixelFormat = MTLPixelFormatRGBA8Unorm;
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

MTL::CommandBuffer* Engine::beginDrawableCommands(bool isPaused) {
	// Wait on the semaphore for the current frame
	dispatch_semaphore_wait(frameSemaphores[currentFrameIndex], DISPATCH_TIME_FOREVER);
	
	MTL::CommandBuffer* commandBuffer = metalCommandQueue->commandBuffer();
	
	MTL::CommandBufferHandler handler = [this](MTL::CommandBuffer*) {
		// Signal the semaphore for this frame when GPU work is complete
		dispatch_semaphore_signal(frameSemaphores[currentFrameIndex]);
	};
	commandBuffer->addCompletedHandler(handler);
	
	updateWorldState(isPaused);
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
    jfaOffsetBuffer.resize(MaxFramesInFlight);
    rcBuffer.resize(MaxFramesInFlight);

	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		frameDataBuffers[frame] = metalDevice->newBuffer(sizeof(FrameData), MTL::ResourceStorageModeShared);
		frameDataBuffers[frame]->setLabel(NS::String::string("FrameData", NS::ASCIIStringEncoding));
        
        // Jump Flood Algorithm
        jfaOffsetBuffer[frame].resize(MAXSTAGES);
        for (int stage = 0; stage < MAXSTAGES; stage++) {
            std::string labelStr = "Frame: " + std::to_string(frame) + "|Stage: " + std::to_string(stage);
            NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
            
            jfaOffsetBuffer[frame][stage] = metalDevice->newBuffer(sizeof(JFAParams), MTL::ResourceStorageModeManaged);
            jfaOffsetBuffer[frame][stage]->setLabel(label);
        }
        
        // Radiance Cascades
        rcBuffer[frame].resize(NUM_OF_CASCADES);
        for (int cascade = 0; cascade < NUM_OF_CASCADES; cascade++) {
            std::string labelStr = "Frame: " + std::to_string(frame) + "|Cascade: " + std::to_string(cascade);
            NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
            
            rcBuffer[frame][cascade] = metalDevice->newBuffer(sizeof(rcParams), MTL::ResourceStorageModeManaged);
            rcBuffer[frame][cascade]->setLabel(label);
        }
	}
}

void Engine::createDefaultLibrary() {
    NS::String* libraryPath = NS::String::string(
        SHADER_METALLIB,
        NS::UTF8StringEncoding);
    
    NS::Error* error = nullptr;

    printf("Selected Device: %s\n", metalDevice->name()->utf8String());
    
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

	frameData->width = (uint)metalLayer.drawableSize.width;
	frameData->height = (uint)metalLayer.drawableSize.height;

	frameData->time = glfwGetTime();
	
	frameData->prevMouse = frameData->mouseCoords.xy;
    frameData->mouseCoords.xy = simd::float2{(float)camera.getLastX(), (float)camera.getLastY()};
	
	frameData->mouseCoords.w = frameData->mouseCoords.z;
	frameData->mouseCoords.z = camera.mousePressed;

	frameData->keyboardDigits = camera.getKeys().digits;
	frameData->frameCount = frameNumber;
}


void Engine::createCommandQueue() {
    metalCommandQueue = metalDevice->newCommandQueue();
}

void Engine::createRenderPipelines() {
	NS::Error* error = nullptr;

	#pragma mark Vertex function setup
	MTL::Function* vertexFunction = metalDefaultLibrary->newFunction(NS::String::string("vertex_function", NS::ASCIIStringEncoding));
	assert(vertexFunction && "Failed to load the vertex function!");

	#pragma mark Drawing Render Pipeline
	{
		MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_drawing", NS::ASCIIStringEncoding));
		assert(fragmentFunction && "Failed to load drawing fragment function!");

		MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		renderPipelineDescriptor->setLabel(NS::String::string("Drawing Render Pipeline", NS::ASCIIStringEncoding));
		renderPipelineDescriptor->setVertexFunction(vertexFunction);
		renderPipelineDescriptor->setFragmentFunction(fragmentFunction);
		renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(pixelFormat);
		
		drawingRenderPipelineState = metalDevice->newRenderPipelineState(renderPipelineDescriptor, &error);
		assert(error == nil && "Failed to create drawing render pipeline state!");

		fragmentFunction->release();
		renderPipelineDescriptor->release();
	}
	
	#pragma mark Seed Render Pipeline
	{
		MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_seed", NS::ASCIIStringEncoding));
		assert(fragmentFunction && "Failed to load seed fragment function!");

		MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		renderPipelineDescriptor->setLabel(NS::String::string("Seed Render Pipeline", NS::ASCIIStringEncoding));
		renderPipelineDescriptor->setVertexFunction(vertexFunction);
		renderPipelineDescriptor->setFragmentFunction(fragmentFunction);
		renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(pixelFormat);
		
		seedRenderPipelineState = metalDevice->newRenderPipelineState(renderPipelineDescriptor, &error);
		assert(error == nil && "Failed to create seed render pipeline state!");

		fragmentFunction->release();
		renderPipelineDescriptor->release();
	}

	#pragma mark JFA Render Pipeline
	{
		MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_jfa", NS::ASCIIStringEncoding));
		assert(fragmentFunction && "Failed to load JFA fragment function!");

		MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		renderPipelineDescriptor->setLabel(NS::String::string("JFA Render Pipeline", NS::ASCIIStringEncoding));
		renderPipelineDescriptor->setVertexFunction(vertexFunction);
		renderPipelineDescriptor->setFragmentFunction(fragmentFunction);
		renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(pixelFormat);
		
		jfaRenderPipelineState = metalDevice->newRenderPipelineState(renderPipelineDescriptor, &error);
		assert(error == nil && "Failed to create JFA render pipeline state!");

		fragmentFunction->release();
		renderPipelineDescriptor->release();
	}
	
	#pragma mark Distance Render Pipeline
	{
		MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_distance", NS::ASCIIStringEncoding));
		assert(fragmentFunction && "Failed to load Distance fragment function!");

		MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		renderPipelineDescriptor->setLabel(NS::String::string("Distance Render Pipeline", NS::ASCIIStringEncoding));
		renderPipelineDescriptor->setVertexFunction(vertexFunction);
		renderPipelineDescriptor->setFragmentFunction(fragmentFunction);
		renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(pixelFormat);
		
		distanceRenderPipelineState = metalDevice->newRenderPipelineState(renderPipelineDescriptor, &error);
		assert(error == nil && "Failed to create Distance render pipeline state!");

		fragmentFunction->release();
		renderPipelineDescriptor->release();
	}

	#pragma mark Composition Render Pipeline
	{
		MTL::Function* fragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_composition", NS::ASCIIStringEncoding));
		assert(fragmentFunction && "Failed to load composition fragment function!");

		MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		renderPipelineDescriptor->setLabel(NS::String::string("Composition Render Pipeline", NS::ASCIIStringEncoding));
		renderPipelineDescriptor->setVertexFunction(vertexFunction);
		renderPipelineDescriptor->setFragmentFunction(fragmentFunction);
		renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(pixelFormat);
		
		compositionRenderPipelineState = metalDevice->newRenderPipelineState(renderPipelineDescriptor, &error);
		assert(error == nil && "Failed to create composition render pipeline state!");

		fragmentFunction->release();
		renderPipelineDescriptor->release();
	}

	vertexFunction->release();
}

#pragma mark createRenderPassDescriptor
void Engine::createRenderPassDescriptor() {
    renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();

	MTL::TextureDescriptor* textureDesc = MTL::TextureDescriptor::alloc()->init();
	textureDesc->setPixelFormat(pixelFormat);
	textureDesc->setWidth(metalLayer.drawableSize.width);
	textureDesc->setHeight(metalLayer.drawableSize.height);
	textureDesc->setUsage(MTL::TextureUsageShaderWrite | MTL::TextureUsageShaderRead | MTL::TextureUsageRenderTarget);
    textureDesc->setStorageMode(MTL::StorageModePrivate);
	textureDesc->setTextureType(MTL::TextureType2D);
	
	jfaTexture = metalDevice->newTexture(textureDesc);
	jfaTexture->setLabel(NS::String::string("jfaTexture", NS::ASCIIStringEncoding));
	drawingTexture = metalDevice->newTexture(textureDesc);
	drawingTexture->setLabel(NS::String::string("drawingTexture", NS::ASCIIStringEncoding));
	distanceTexture = metalDevice->newTexture(textureDesc);
	distanceTexture->setLabel(NS::String::string("distanceTexture", NS::ASCIIStringEncoding));
	seedTexture = metalDevice->newTexture(textureDesc);
	seedTexture->setLabel(NS::String::string("seedTexture", NS::ASCIIStringEncoding));
}

void Engine::updateRenderPassDescriptor() {
    if (!renderPassDescriptor) {
        createRenderPassDescriptor();
    }

    // Update the drawable texture for rendering
    renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());
}

#pragma mark drawTexture
void Engine::drawTexture(MTL::CommandBuffer* commandBuffer) {
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
    renderPass->colorAttachments()->object(0)->setTexture(drawingTexture);
    renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionLoad);
    renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);

    MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
    renderCommandEncoder->pushDebugGroup(NS::String::string("Drawing Render Pass", NS::ASCIIStringEncoding));
	
    renderCommandEncoder->setRenderPipelineState(drawingRenderPipelineState);
	
    renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
	
    renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
    renderCommandEncoder->popDebugGroup();
    renderCommandEncoder->endEncoding();
	
    renderPass->release();
}

#pragma mark drawSeed
void Engine::drawSeed(MTL::CommandBuffer* commandBuffer) {
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
	renderPass->colorAttachments()->object(0)->setTexture(seedTexture);
	renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
	renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
	renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));

	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
	renderCommandEncoder->pushDebugGroup(NS::String::string("Seed Render Pass", NS::ASCIIStringEncoding));

	renderCommandEncoder->setRenderPipelineState(seedRenderPipelineState);

	renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	renderCommandEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);

	renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);

	renderCommandEncoder->popDebugGroup();
	renderCommandEncoder->endEncoding();

	renderPass->release();
}

#pragma mark JFAPass
void Engine::JFAPass(MTL::CommandBuffer* commandBuffer) {
	MTL::TextureDescriptor* desc = MTL::TextureDescriptor::texture2DDescriptor(
		metalDrawable->layer()->pixelFormat(),
		metalDrawable->layer()->drawableSize().width,
		metalDrawable->layer()->drawableSize().height,
		false);
	
	desc->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite | MTL::TextureUsageRenderTarget);
    desc->setStorageMode(MTL::StorageModePrivate);
	
	MTL::Texture* renderA = metalDevice->newTexture(desc);
	MTL::Texture* renderB = metalDevice->newTexture(desc);
	
	MTL::Texture* currentInput = seedTexture;
	MTL::Texture* currentOutput = renderA;
    MTL::Texture* lastUsedTexture = nullptr;
	
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
    renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
    renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));

    for (int stage = 0; stage < jfaPasses; ++stage) {
        renderPass->colorAttachments()->object(0)->setTexture(currentOutput);
        if (stage > 0)
            renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionLoad);
        renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
        
		JFAParams* params = (JFAParams*)(jfaOffsetBuffer[currentFrameIndex][stage]->contents());

		MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
		std::string labelStr = "Stage: " + std::to_string(stage);
		NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
        renderCommandEncoder->setLabel(label);
		
        renderCommandEncoder->pushDebugGroup(NS::String::string("Jump Flood Algorithm Render Pass", NS::ASCIIStringEncoding));
        renderCommandEncoder->setRenderPipelineState(jfaRenderPipelineState);
		
        params->uOffset = pow(2.0, jfaPasses - stage - 1);
        params->skip = (jfaPasses == 0) ? 1 : 0;
        params->oneOverSize = simd::float2{1.0f / (float)metalDrawable->layer()->drawableSize().width, 1.0f / (float)metalDrawable->layer()->drawableSize().height};

        renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
        renderCommandEncoder->setFragmentBuffer(jfaOffsetBuffer[currentFrameIndex][stage], 0, BufferIndexJFAParams);
        renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
        renderCommandEncoder->setFragmentTexture(currentInput, TextureIndexDrawing);
		
        renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
		
        renderCommandEncoder->popDebugGroup();
        renderCommandEncoder->endEncoding();
	
		currentInput = currentOutput;
		currentOutput = (currentOutput == renderA) ? renderB : renderA;
        lastUsedTexture = currentInput;
	}
	
	// Copy the final result to jfaTexture
    MTL::BlitCommandEncoder* blitEncoder = commandBuffer->blitCommandEncoder();
    MTL::Origin origin = MTL::Origin(0, 0, 0);
    MTL::Size size = MTL::Size(jfaTexture->width(), jfaTexture->height(), 1);
    blitEncoder->copyFromTexture(lastUsedTexture, 0, 0, origin, size, jfaTexture, 0, 0, origin);
    blitEncoder->endEncoding();

    // Add a completion handler to safely release resources
    commandBuffer->addCompletedHandler(^void(MTL::CommandBuffer*) {
        renderA->release();
        renderB->release();
    });

    renderPass->release();
}

#pragma mark drawDistanceTexture
void Engine::drawDistanceTexture(MTL::CommandBuffer* commandBuffer) {
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
	renderPass->colorAttachments()->object(0)->setTexture(distanceTexture);
    renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
    renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));


	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
	renderCommandEncoder->pushDebugGroup(NS::String::string("Distance Render Pass", NS::ASCIIStringEncoding));
	
	renderCommandEncoder->setRenderPipelineState(distanceRenderPipelineState);
	
	renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	renderCommandEncoder->setFragmentTexture(jfaTexture, TextureIndexJFA);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	
	renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
	renderCommandEncoder->popDebugGroup();
	renderCommandEncoder->endEncoding();
	
	renderPass->release();
}

#pragma mark rcPass
void Engine::rcPass(MTL::CommandBuffer *commandBuffer) {
    uint width = metalDrawable->layer()->drawableSize().width;
    uint height = metalDrawable->layer()->drawableSize().height;
    
    MTL::TextureDescriptor* desc = MTL::TextureDescriptor::texture2DDescriptor(
        metalDrawable->layer()->pixelFormat(),
        width,
        height,
        false);
    
    desc->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageRenderTarget);
    
    MTL::Texture* rcRenderTargets[2];
    rcRenderTargets[0] = metalDevice->newTexture(desc);
    rcRenderTargets[1] = metalDevice->newTexture(desc);
    
    MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
    renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
    renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));
    renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
    
    const float diagonal = sqrtf(width * width + height * height);
    float cascadeCount = ceil(log(diagonal) / logf(baseRayCount)) + 1;

    cascadeCount = std::min(cascadeCount, static_cast<float>(NUM_OF_CASCADES));
    
    MTL::Texture* lastMergeTexture = nil;
    int pingPongIndex = 0;
    
    for (int cascade = cascadeCount - 1; cascade >= 0; cascade--) {
        rcParams* params = reinterpret_cast<rcParams*>(rcBuffer[currentFrameIndex][cascade]->contents());
        
        params->cascadeCount = cascadeCount;
        params->base = baseRayCount;
        params->rayCount = pow(baseRayCount, cascade + 1);
        params->cascadeIndex = cascade;
        
        MTL::Texture* currentRenderTarget = nullptr;
        
        if (cascade == cascadeCount - 1) {
            currentRenderTarget = rcRenderTargets[pingPongIndex];
            pingPongIndex = 1 - pingPongIndex;
            lastMergeTexture = nullptr;
        } else if (cascade > 0) {
            currentRenderTarget = rcRenderTargets[pingPongIndex];
            pingPongIndex = 1 - pingPongIndex;
        } else {
            currentRenderTarget = metalDrawable->texture();
        }
        
        renderPass->colorAttachments()->object(0)->setTexture(currentRenderTarget);
        
        MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
        
        std::string labelStr = "Cascade: " + std::to_string(cascade);
        NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
        renderCommandEncoder->setLabel(label);
        renderCommandEncoder->pushDebugGroup(NS::String::string("Radiance Cascades Render Pass", NS::ASCIIStringEncoding));
        
        renderCommandEncoder->setRenderPipelineState(compositionRenderPipelineState);
        renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
        
        // textures
        renderCommandEncoder->setFragmentTexture(distanceTexture, TextureIndexDistance);
        renderCommandEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
        renderCommandEncoder->setFragmentTexture(lastMergeTexture, TextureIndexLast);
        
        // buffers
        renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
        renderCommandEncoder->setFragmentBuffer(rcBuffer[currentFrameIndex][cascade], 0, BufferIndexRCParams);
        
        renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
        
        renderCommandEncoder->popDebugGroup();
        renderCommandEncoder->endEncoding();
        
        if (cascade > 0) {
            lastMergeTexture = currentRenderTarget;
        }
    }
    
    renderPass->release();
    rcRenderTargets[0]->release();
    rcRenderTargets[1]->release();
}

// Unused
void Engine::performComposition(MTL::CommandBuffer* commandBuffer) {
	renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());

	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPassDescriptor);
    renderCommandEncoder->pushDebugGroup(NS::String::string("Composition Render Pass", NS::ASCIIStringEncoding));
	
    renderCommandEncoder->setRenderPipelineState(compositionRenderPipelineState);
	
    renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentTexture(distanceTexture, TextureIndexDistance);
    renderCommandEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
	
    renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
    renderCommandEncoder->popDebugGroup();
    renderCommandEncoder->endEncoding();
}

#pragma mark draw
void Engine::draw() {
	MTL::CommandBuffer* commandBuffer = beginDrawableCommands(false);
	if (commandBuffer) {
		drawTexture(commandBuffer);
		drawSeed(commandBuffer);
        JFAPass(commandBuffer);
		drawDistanceTexture(commandBuffer);
        rcPass(commandBuffer);

		endFrame(commandBuffer, metalDrawable);
	}
}
