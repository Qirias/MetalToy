#include "engine.hpp"

Engine::Engine()
: camera(simd::float3{0.0f, 0.0f, 3.0f}, 0.1, 1000)
, lastFrame(0.0f)
, frameNumber(0)
, currentFrameIndex(0)
, pixelFormat(MTL::PixelFormatRGBA16Float) {
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
	
	for(uint8_t frame = 0; frame < MaxFramesInFlight; frame++) {
		frameDataBuffers[frame]->release();
    }
	
	drawingTexture->release();
	renderPassDescriptor->release();
	drawingRenderPipelineState->release();
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
    metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
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

#pragma mark performComposition
void Engine::performComposition(MTL::CommandBuffer* commandBuffer) {
	renderPassDescriptor->colorAttachments()->object(0)->setTexture(metalDrawable->texture());

	MTL::RenderCommandEncoder* renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPassDescriptor);
    renderCommandEncoder->pushDebugGroup(NS::String::string("Composition Render Pass", NS::ASCIIStringEncoding));
	
    renderCommandEncoder->setRenderPipelineState(compositionRenderPipelineState);
	
    renderCommandEncoder->setVertexBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
    renderCommandEncoder->setFragmentBuffer(frameDataBuffers[currentFrameIndex], 0, BufferIndexFrameData);
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
        performComposition(commandBuffer);
        
		endFrame(commandBuffer, metalDrawable);
	}
}
