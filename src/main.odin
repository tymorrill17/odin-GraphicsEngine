package main

import "graphics"

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

    renderer_config := graphics.RendererConfig{
        app_name            = "Renderer",
        extent              = {APPLICATION_WIDTH, APPLICATION_HEIGHT},
        use_discrete_GPU    = true,
        validation_layers   = requested_validation_layers,
        device_extensions   = requested_device_extensions
    }

    renderer: graphics.Renderer
    graphics.renderer_initialize(&renderer, renderer_config)
    defer graphics.renderer_shutdown(&renderer)

    for !graphics.window_should_close(renderer) {
        graphics.poll_events()
    }

}
