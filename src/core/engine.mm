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
		jfaOffsetBuffer[i]->release();
    }
	
	drawingTexture->release();
	jfaTexture->release();
	renderPassDescriptor->release();
	drawingRenderPipelineState->release();
	jfaRenderPipelineState->release();
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
    glfwWindow = glfwCreateWindow(800, 800, "MetalToy", NULL, NULL);
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
	for(uint8_t i = 0; i < MaxFramesInFlight; i++) {
		frameDataBuffers[i] = metalDevice->newBuffer(sizeof(FrameData), MTL::ResourceStorageModeShared);
		frameDataBuffers[i]->setLabel(NS::String::string("FrameData", NS::ASCIIStringEncoding));
		
		jfaOffsetBuffer[i] = metalDevice->newBuffer(sizeof(JFAParams), MTL::ResourceStorageModeShared);
		jfaOffsetBuffer[i]->setLabel(NS::String::string("jfaOffset", NS::ASCIIStringEncoding));

	}
}

void Engine::createDefaultLibrary() {
    NS::String* libraryPath = NS::String::string(
        SHADER_METALLIB,
        NS::UTF8StringEncoding
    );
    
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
		MTL::Function* drawingFragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_drawing", NS::ASCIIStringEncoding));
		assert(drawingFragmentFunction && "Failed to load drawing fragment function!");

		MTL::RenderPipelineDescriptor* drawingPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		drawingPipelineDescriptor->setLabel(NS::String::string("Drawing Render Pipeline", NS::ASCIIStringEncoding));
		drawingPipelineDescriptor->setVertexFunction(vertexFunction);
		drawingPipelineDescriptor->setFragmentFunction(drawingFragmentFunction);
		drawingPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
		
		drawingRenderPipelineState = metalDevice->newRenderPipelineState(drawingPipelineDescriptor, &error);
		assert(error == nil && "Failed to create drawing render pipeline state!");

		drawingFragmentFunction->release();
		drawingPipelineDescriptor->release();
	}

	#pragma mark JFA Render Pipeline
	{
		MTL::Function* jfaFragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_jfa", NS::ASCIIStringEncoding));
		assert(jfaFragmentFunction && "Failed to load JFA fragment function!");

		MTL::RenderPipelineDescriptor* jfaPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		jfaPipelineDescriptor->setLabel(NS::String::string("JFA Render Pipeline", NS::ASCIIStringEncoding));
		jfaPipelineDescriptor->setVertexFunction(vertexFunction);
		jfaPipelineDescriptor->setFragmentFunction(jfaFragmentFunction);
		jfaPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
		
		jfaRenderPipelineState = metalDevice->newRenderPipelineState(jfaPipelineDescriptor, &error);
		assert(error == nil && "Failed to create JFA render pipeline state!");

		jfaFragmentFunction->release();
		jfaPipelineDescriptor->release();
	}

	#pragma mark Composition Render Pipeline
	{
		MTL::Function* compositionFragmentFunction = metalDefaultLibrary->newFunction(NS::String::string("fragment_composition", NS::ASCIIStringEncoding));
		assert(compositionFragmentFunction && "Failed to load composition fragment function!");

		MTL::RenderPipelineDescriptor* compositionPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
		compositionPipelineDescriptor->setLabel(NS::String::string("Composition Render Pipeline", NS::ASCIIStringEncoding));
		compositionPipelineDescriptor->setVertexFunction(vertexFunction);
		compositionPipelineDescriptor->setFragmentFunction(compositionFragmentFunction);
		compositionPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
		
		compositionRenderPipelineState = metalDevice->newRenderPipelineState(compositionPipelineDescriptor, &error);
		assert(error == nil && "Failed to create composition render pipeline state!");

		compositionFragmentFunction->release();
		compositionPipelineDescriptor->release();
	}

	vertexFunction->release();
}

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
	textureDesc->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
	textureDesc->setWidth(metalLayer.drawableSize.width);
	textureDesc->setHeight(metalLayer.drawableSize.height);
	textureDesc->setUsage(MTL::TextureUsageShaderWrite | MTL::TextureUsageShaderRead | MTL::TextureUsageRenderTarget);
    textureDesc->setStorageMode(MTL::StorageModePrivate);
	textureDesc->setTextureType(MTL::TextureType2D);
	
	jfaTexture = metalDevice->newTexture(textureDesc);
	jfaTexture->setLabel(NS::String::string("jfaTexture", NS::ASCIIStringEncoding));
	drawingTexture = metalDevice->newTexture(textureDesc);
	drawingTexture->setLabel(NS::String::string("drawingTexture", NS::ASCIIStringEncoding));
}

void Engine::updateRenderPassDescriptor() {
    if (!renderPassDescriptor) {
        createRenderPassDescriptor();
    }

    // Update the drawable texture for rendering
    renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());
}

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

void Engine::performJFA(MTL::CommandBuffer* commandBuffer) {
	MTL::TextureDescriptor* desc = MTL::TextureDescriptor::texture2DDescriptor(
		metalDrawable->layer()->pixelFormat(),
		metalDrawable->layer()->drawableSize().width,
		metalDrawable->layer()->drawableSize().height,
		false);
	
	desc->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageShaderWrite | MTL::TextureUsageRenderTarget);
	
	MTL::Texture* renderA = metalDevice->newTexture(desc);
	MTL::Texture* renderB = metalDevice->newTexture(desc);
	
	MTL::Texture* currentInput = drawingTexture;
	MTL::Texture* currentOutput = renderA;

	int passes = ceil(log2(max(float(jfaTexture->width()), float(jfaTexture->height())))); // 10

	JFAParams* params = (JFAParams*)(jfaOffsetBuffer[currentFrameIndex]->contents());
	constexpr int STAGES = 6;
	std::array<MTL::Fence*, STAGES> fences{};
	for (int i = 0; i < STAGES; i++) {
		fences[i] = metalDevice->newFence();
	}
	
	MTL::RenderPassDescriptor* jfaRenderPass = MTL::RenderPassDescriptor::alloc()->init();


	for (int i = 0; i < STAGES || (passes == 0 && i == 0); ++i) {
		jfaRenderPass->colorAttachments()->object(0)->setTexture(currentOutput);
		jfaRenderPass->colorAttachments()->object(0)->setLoadAction(MTL::LoadActionLoad);
		jfaRenderPass->colorAttachments()->object(0)->setStoreAction(MTL::StoreActionStore);
		
		MTL::RenderCommandEncoder* jfaEncoder = commandBuffer->renderCommandEncoder(jfaRenderPass);
		
		if (i > 0) {
			jfaEncoder->waitForFence(fences[i-1], MTL::RenderStageFragment);
		}
		
		jfaEncoder->updateFence(fences[i], MTL::RenderStageFragment);
		
		jfaEncoder->pushDebugGroup(NS::String::string("Jump Flood Algorithm Render Pass", NS::ASCIIStringEncoding));
		
		jfaEncoder->setRenderPipelineState(jfaRenderPipelineState);
		
		params->uOffset = pow(2.0, passes - i - 1); // 512 256 .. 1
		params->skip = (passes == 0) ? 1 : 0;
		params->oneOverSize = simd::float2{1.0f / jfaTexture->width(), 1.0f / jfaTexture->height()};

		jfaEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
		jfaEncoder->setFragmentBuffer(jfaOffsetBuffer[currentFrameIndex], 0, BufferIndexJFAParams);
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
	
	blitEncoder->copyFromTexture(
		currentInput,   // Source is the last currentInput (either renderA or renderB)
		0,              // source level
		0,              // source slice
		origin,         // source origin
		size,           // source size
		jfaTexture,     // Destination is always jfaTexture
		0,              // destination level
		0,              // destination slice
		origin          // destination origin
	);
	
	blitEncoder->endEncoding();

	renderA->release();
	renderB->release();
	
	for (int i = 0; i < STAGES; i++) {
		fences[i]->release();
	}

	jfaRenderPass->release();
}

void Engine::performComposition(MTL::CommandBuffer* commandBuffer) {
	
	renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());

	MTL::RenderCommandEncoder* compositionEncoder = commandBuffer->renderCommandEncoder(renderPassDescriptor);
	compositionEncoder->pushDebugGroup(NS::String::string("Composition Render Pass", NS::ASCIIStringEncoding));
	
	compositionEncoder->setRenderPipelineState(compositionRenderPipelineState);
	
	compositionEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	compositionEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
	compositionEncoder->setFragmentTexture(jfaTexture, TextureIndexJFA);
	compositionEncoder->setFragmentTexture(drawingTexture, TextureIndexDrawing);
	
	compositionEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, 0, 3, 1);
	
	compositionEncoder->popDebugGroup();
	compositionEncoder->endEncoding();
}

void Engine::draw() {
	MTL::CommandBuffer* commandBuffer = beginDrawableCommands(false);
	if (commandBuffer) {
		drawTexture(commandBuffer);
		performJFA(commandBuffer);
		performComposition(commandBuffer);

		endFrame(commandBuffer, metalDrawable);
	}
}
