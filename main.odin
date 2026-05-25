package main

import "engine"

APPLICATION_WIDTH  :: 1920
APPLICATION_HEIGHT :: 1080

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type"
}

main :: proc() {
    renderer := engine.renderer_create("Renderer", APPLICATION_WIDTH, APPLICATION_HEIGHT, requested_validation_layers, requested_device_extensions)
    defer engine.renderer_destroy(&renderer)

    for !engine.window_should_close(renderer) {
        engine.poll_events()
    }

}
