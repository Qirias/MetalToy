#include "engine.hpp"

Engine::Engine()
: camera(simd::float3{0.0f, 0.0f, 3.0f}, 0.1, 1000)
, lastFrame(0.0f)
, frameNumber(0)
, currentFrameIndex(0)
, pixelFormat(MTL::PixelFormatRGBA8Unorm)
, jfaPasses(0) {
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
    }
	
	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		for(uint8_t stage = 0; stage < MAXSTAGES; stage++) {
			jfaOffsetBuffer[frame][stage]->release();
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
	if (drawingTexture) { drawingTexture->release(); 	drawingTexture = nullptr; }
	if (jfaTexture) { jfaTexture->release(); 			jfaTexture = nullptr; }
	
	createRenderPassDescriptor();
    metalDrawable = (__bridge CA::MetalDrawable*)[metalLayer nextDrawable];
    updateRenderPassDescriptor();
}

void Engine::initWindow() {
    glfwInit();
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindow = glfwCreateWindow(1024, 1024, "MetalToy", NULL, NULL);
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
	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		frameDataBuffers[frame] = metalDevice->newBuffer(sizeof(FrameData), MTL::ResourceStorageModeShared);
		frameDataBuffers[frame]->setLabel(NS::String::string("FrameData", NS::ASCIIStringEncoding));
	}
	
	jfaOffsetBuffer.resize(MaxFramesInFlight);
	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		jfaOffsetBuffer[frame].resize(MAXSTAGES);
		for (int stage = 0; stage < MAXSTAGES; stage++) {
			std::string labelStr = "Frame: " + std::to_string(frame) + "|Stage: " + std::to_string(stage);
			NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
			
			jfaOffsetBuffer[frame][stage] = metalDevice->newBuffer(sizeof(JFAParams), MTL::ResourceStorageModeManaged);
			jfaOffsetBuffer[frame][stage]->setLabel(label);
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

	frameData->framebuffer_width = (uint)metalLayer.drawableSize.width;
	frameData->framebuffer_height = (uint)metalLayer.drawableSize.height;

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

    MTL::SamplerDescriptor* samplerDescriptor = MTL::SamplerDescriptor::alloc()->init();
	samplerDescriptor->setMinFilter(MTL::SamplerMinMagFilterLinear);
    samplerDescriptor->setMagFilter(MTL::SamplerMinMagFilterLinear);
	samplerDescriptor->setMipFilter(MTL::SamplerMipFilterNotMipmapped);
    samplerDescriptor->setSAddressMode(MTL::SamplerAddressModeClampToEdge);
    samplerDescriptor->setTAddressMode(MTL::SamplerAddressModeClampToEdge);
    samplerState = metalDevice->newSamplerState(samplerDescriptor);

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
	MTL::RenderPassDescriptor* drawingRenderPass = MTL::RenderPassDescriptor::alloc()->init();
	drawingRenderPass->colorAttachments()->object(0)->setTexture(drawingTexture);
	drawingRenderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionLoad);
	drawingRenderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
	drawingRenderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(0.0, 0.0, 0.0, 1.0));

	MTL::RenderCommandEncoder* drawingEncoder = commandBuffer->renderCommandEncoder(drawingRenderPass);
	drawingEncoder->pushDebugGroup(NS::String::string("Drawing Render Pass", NS::ASCIIStringEncoding));
	
	drawingEncoder->setRenderPipelineState(drawingRenderPipelineState);
	
	drawingEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	drawingEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	drawingEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
	
	drawingEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
	drawingEncoder->popDebugGroup();
	drawingEncoder->endEncoding();
	
	drawingRenderPass->release();
}

#pragma mark drawSeed
void Engine::drawSeed(MTL::CommandBuffer* commandBuffer) {
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
	renderPass->colorAttachments()->object(0)->setTexture(seedTexture);
	renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionClear);
	renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
	renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(1.0, 1.0, 1.0, 1.0));

	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
	renderCommandEncoder->pushDebugGroup(NS::String::string("Seed Render Pass", NS::ASCIIStringEncoding));

	renderCommandEncoder->setRenderPipelineState(seedRenderPipelineState);

	renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBytes(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	renderCommandEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);

	renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);

	renderCommandEncoder->popDebugGroup();
	renderCommandEncoder->endEncoding();

	renderPass->release();
}

#pragma mark performJFA
void Engine::performJFA(MTL::CommandBuffer* commandBuffer) {
	MTL::TextureDescriptor* desc = MTL::TextureDescriptor::texture2DDescriptor(
		metalDrawable->layer()->pixelFormat(),
		metalDrawable->layer()->drawableSize().width,
		metalDrawable->layer()->drawableSize().height,
		false);
	
	desc->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite | MTL::TextureUsageRenderTarget);
	
	MTL::Texture* renderA = metalDevice->newTexture(desc);
	MTL::Texture* renderB = metalDevice->newTexture(desc);
	
	MTL::Texture* currentInput = seedTexture;
	MTL::Texture* currentOutput = renderA;
	
	MTL::RenderPassDescriptor* jfaRenderPass = MTL::RenderPassDescriptor::alloc()->init();

	for (int stage = 0; stage < jfaPasses || (jfaPasses == 0 && stage == 0); ++stage) {
		jfaRenderPass->colorAttachments()->object(0)->setTexture(currentOutput);
		JFAParams* params = (JFAParams*)(jfaOffsetBuffer[currentFrameIndex][stage]->contents());

		MTL::RenderCommandEncoder* jfaEncoder = commandBuffer->renderCommandEncoder(jfaRenderPass);
		std::string labelStr = "Stage: " + std::to_string(stage);
		NS::String* label = NS::String::string(labelStr.c_str(), NS::ASCIIStringEncoding);
		jfaEncoder->setLabel(label);
		
		jfaEncoder->pushDebugGroup(NS::String::string("Jump Flood Algorithm Render Pass", NS::ASCIIStringEncoding));
		jfaEncoder->setRenderPipelineState(jfaRenderPipelineState);
		
		params->uOffset = pow(2.0, jfaPasses - stage - 1);
		params->skip = (jfaPasses == 0) ? 1 : 0;
		params->oneOverSize = simd::float2{1.0f / jfaTexture->width(), 1.0f / jfaTexture->height()};

		jfaEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
		jfaEncoder->setFragmentBuffer(jfaOffsetBuffer[currentFrameIndex][stage], 0, BufferIndexJFAParams);
        jfaEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
		jfaEncoder->setFragmentTexture(currentInput, TextureIndexDrawing);
		
		jfaEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
		
		jfaEncoder->popDebugGroup();
		jfaEncoder->endEncoding();
	
		currentInput = currentOutput;
		currentOutput = (currentOutput == renderA) ? renderB : renderA;
	}
	

	// Copy the final result to jfaTexture
	MTL::BlitCommandEncoder* blitEncoder = commandBuffer->blitCommandEncoder();
	MTL::Origin origin = MTL::Origin(0, 0, 0);
	MTL::Size size = MTL::Size(jfaTexture->width(), jfaTexture->height(), 1);
	blitEncoder->copyFromTexture(currentInput, 0, 0, origin, size, jfaTexture, 0, 0, origin);
	blitEncoder->endEncoding();

	renderA->release();
	renderB->release();
	jfaRenderPass->release();
}

#pragma mark drawDistanceTexture
void Engine::drawDistanceTexture(MTL::CommandBuffer* commandBuffer) {
	MTL::RenderPassDescriptor* renderPass = MTL::RenderPassDescriptor::alloc()->init();
	renderPass->colorAttachments()->object(0)->setTexture(distanceTexture);
	renderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionLoad);
	renderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
	renderPass->colorAttachments()->object(0)->setClearColor(MTL::ClearColor(1.0, 1.0, 1.0, 1.0));

	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPass);
	renderCommandEncoder->pushDebugGroup(NS::String::string("Distance Render Pass", NS::ASCIIStringEncoding));
	
	renderCommandEncoder->setRenderPipelineState(distanceRenderPipelineState);
	
	renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	renderCommandEncoder->setFragmentTexture(jfaTexture, TextureIndexJFA);
    renderCommandEncoder->setFragmentBytes(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	
	renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
	renderCommandEncoder->popDebugGroup();
	renderCommandEncoder->endEncoding();
	
	renderPass->release();
}

#pragma mark performComposition
void Engine::performComposition(MTL::CommandBuffer* commandBuffer) {
	renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());

	MTL::RenderCommandEncoder* compositionEncoder = commandBuffer->renderCommandEncoder(renderPassDescriptor);
	compositionEncoder->pushDebugGroup(NS::String::string("Composition Render Pass", NS::ASCIIStringEncoding));
	
	compositionEncoder->setRenderPipelineState(compositionRenderPipelineState);
	
	compositionEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	compositionEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	compositionEncoder->setFragmentTexture(distanceTexture, TextureIndexDistance);
	compositionEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
	
	compositionEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
	compositionEncoder->popDebugGroup();
	compositionEncoder->endEncoding();
}

#pragma mark draw
void Engine::draw() {
	MTL::CommandBuffer* commandBuffer = beginDrawableCommands(false);
	if (commandBuffer) {
		drawTexture(commandBuffer);
		drawSeed(commandBuffer);
		performJFA(commandBuffer);
		drawDistanceTexture(commandBuffer);
		performComposition(commandBuffer);

		endFrame(commandBuffer, metalDrawable);
	}
}
