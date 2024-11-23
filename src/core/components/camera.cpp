#include "camera.hpp"

void Camera::setProjectionMatrix(float fovInDegrees, float aspectRatio, float nearPlane, float farPlane) {
	this->aspectRatio = aspectRatio;
	this->fov = fovInDegrees;
	this->nearPlane = nearPlane;
	this->farPlane = farPlane;
	
	projectionMatrix = matrix_perspective_right_hand(
		fov * (M_PI / 180.0f),
		aspectRatio,
		nearPlane,
		farPlane
	);
}

void Camera::updateCameraVectors() {
	simd::float3 newFront;
	newFront.x = cos(yaw * M_PI / 180.0f) * cos(pitch * M_PI / 180.0f);
	newFront.y = sin(pitch * M_PI / 180.0f);
	newFront.z = sin(yaw * M_PI / 180.0f) * cos(pitch * M_PI / 180.0f);
	
	front = simd::normalize(newFront);
	right = simd::normalize(simd::cross(front, worldUp));
	up = simd::normalize(simd::cross(right, front));
	
	// Update view matrix after camera vectors change
	setViewMatrix();
}

void Camera::processKeyboardInput(GLFWwindow* window, float deltaTime) {
	float velocity = movementSpeed * deltaTime;
	bool moved = false;
	
	if (glfwGetKey(window, keys.moveForward) == GLFW_PRESS) {
		position += front * velocity;
		moved = true;
	}
	if (glfwGetKey(window, keys.moveBackward) == GLFW_PRESS) {
		position -= front * velocity;
		moved = true;
	}
	if (glfwGetKey(window, keys.moveLeft) == GLFW_PRESS) {
		position -= right * velocity;
		moved = true;
	}
	if (glfwGetKey(window, keys.moveRight) == GLFW_PRESS) {
		position += right * velocity;
		moved = true;
	}
	if (glfwGetKey(window, keys.moveUp) == GLFW_PRESS) {
		position += up * velocity;
		moved = true;
	}
	if (glfwGetKey(window, keys.moveDown) == GLFW_PRESS) {
		position -= up * velocity;
		moved = true;
	}

	keys.digits = 0;
	// Detect digits 0-9 and store their state in a bitmask
    for (int i = GLFW_KEY_0; i <= GLFW_KEY_9; ++i) {
        if (glfwGetKey(window, i) == GLFW_PRESS) {
            keys.digits |= (1 << (i - GLFW_KEY_0));
        }
    }
	
	// Update view matrix only if the camera moved
	if (moved) {
		setViewMatrix();
	}
	
	if (glfwGetKey(window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
		glfwSetWindowShouldClose(window, true);
	}
}


void Camera::processMouseButton(GLFWwindow* window, int button, int action) {
    if (button == GLFW_MOUSE_BUTTON_LEFT) {
        if (action == GLFW_PRESS) {
            isDragging = true;
			mousePressed = 1.0f;

            // Store the current cursor position as the last position
            glfwGetCursorPos(window, &lastX, &lastY);
        } else if (action == GLFW_RELEASE) {
            isDragging = false;
			mousePressed = 0.0f;
        }
    }
}

void Camera::processMouseMovement(float xpos, float ypos) {
    if (!isDragging) return;
    
    float xoffset = xpos - lastX;
    float yoffset = lastY - ypos;
    lastX = xpos;
    lastY = ypos;
    
    xoffset *= mouseSensitivity;
    yoffset *= mouseSensitivity;
    
    yaw += xoffset;
    pitch += yoffset;
	
    updateCameraVectors();
}

void Camera::setFrustumCornersWorldSpace(simd::float3* frustumCorners, float nearZ, float farZ) {
	const auto inv = matrix_invert(matrix_multiply(projectionMatrix, viewMatrix));
	int cornerIndex = 0;
	
	for (unsigned int x = 0; x < 2; x++) {
		for (unsigned int y = 0; y < 2; y++) {
			for (unsigned int z = 0; z < 2; z++) {
				// Create homogeneous coordinates
				simd::float4 pt = matrix_multiply(inv, simd::float4{
					2.0f * x - 1.0f,
					2.0f * y - 1.0f,
					z == 0 ? nearZ : farZ,  // Use actual near/far values
					1.0f
				});
				
				// Perform perspective division
				float invW = 1.0f / pt.w;
				frustumCorners[cornerIndex++] = simd::float3{
					pt.x * invW,
					pt.y * invW,
					pt.z * invW
				};
			}
		}
	}
}
