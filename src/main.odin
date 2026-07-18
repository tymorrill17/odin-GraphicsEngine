package main

import "thirdparty:imgui"
import "renderer"
import "core:log"

APPLICATION_WIDTH  :: 1280
APPLICATION_HEIGHT :: 720

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type"
}

main :: proc() {

    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger

    renderer_config := renderer.RendererConfig{
        app_name                        = "Renderer",
        extent                          = {APPLICATION_WIDTH, APPLICATION_HEIGHT},
        use_discrete_GPU                = true,
        validation_layers               = requested_validation_layers,
        device_extensions               = requested_device_extensions,
        initial_descriptor_set_count    = 10,
    }

    r: renderer.Renderer
    renderer.renderer_initialize(&r, renderer_config)
    defer renderer.renderer_shutdown(&r)

    for !renderer.window_should_close(&r) {
        renderer.start_frame(&r)

        imgui.ShowDemoWindow()

        renderer.draw(&r)
    }
}
