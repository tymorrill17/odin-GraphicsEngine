package renderer

import "vendor:glfw"
import "core:log"

Window :: struct {
    glfw_window:        glfw.WindowHandle,
    glfw_monitor:       glfw.MonitorHandle,
    glfw_mode:          ^glfw.VidMode,

    extent:             int2, // The size of the window, not accounting for desktop scaling
    draw_extent:        int2, // The number of pixels the extent takes up. (== extent * scale)
    aspect_ratio:       f32,
    position:           int2,
    scale:              float2,

    // To save the windowed position and size when going into fullscreen
    saved_position:     int2,
    saved_extent:       int2,

    should_close:       bool,
    minimized:          bool,
    fullscreen:         bool,
    resized:            bool,
}

window_create :: proc(width, height: i32, name: cstring) -> Window {
    window: Window

    window.should_close = false
    window.fullscreen   = false
    window.resized      = false
    window.minimized    = false

    if !glfw.Init() {
        log.panic("GLFW initialization failed!")
    }

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
    glfw.WindowHint(glfw.VISIBLE, glfw.TRUE)
    window.glfw_window = glfw.CreateWindow(
        width,
        height,
        name,
        nil, // May specify a monitor here to start in fullscreen
        nil)

    if window.glfw_window == nil {
        log.panic("Window creation failure")
    }
    log.infof("Created a window titled: %s", name);

    window.glfw_monitor = glfw.GetPrimaryMonitor()
    if window.glfw_monitor == nil {
        log.panic("Failed to find monitor!")
    }

    window.glfw_mode = glfw.GetVideoMode(window.glfw_monitor)
    if window.glfw_mode == nil {
        log.panic("Failed to get video mode!")
    }

    glfw.ShowWindow(window.glfw_window)
    update_window_info(&window)
    return window
}

window_destroy :: proc(window: ^Window) {
    glfw.DestroyWindow(window.glfw_window)
    glfw.Terminate()
}

set_fullscreen :: proc(window: ^Window, enable: bool) {
    if enable {
        window.saved_extent.x, window.saved_extent.y     = glfw.GetWindowSize(window.glfw_window)
        window.saved_position.x, window.saved_position.y = glfw.GetWindowPos(window.glfw_window)

        glfw.SetWindowMonitor(window.glfw_window, window.glfw_monitor, 0, 0,
            window.glfw_mode.width, window.glfw_mode.height, window.glfw_mode.refresh_rate)
    } else { // disable
        glfw.SetWindowMonitor(window.glfw_window, nil,
            window.saved_position.x, window.saved_position.y,
            window.saved_extent.x, window.saved_extent.y, 0)
    }

    window.fullscreen = enable
    window.resized    = true
}

poll_events :: proc() {
    glfw.PollEvents()
}

@(private)
get_required_vulkan_extensions :: proc(using_validation_layers: bool) -> [dynamic]cstring {
    extensions_cstr := glfw.GetRequiredInstanceExtensions()
    extensions := make([dynamic]cstring, 0, len(extensions_cstr))
    for extension in extensions_cstr {
        append(&extensions, extension)
    }
    if using_validation_layers {
        append(&extensions, "VK_EXT_debug_utils")
    }
    return extensions
}

@(private="file")
update_window_info :: proc(window: ^Window) {
    window.scale.x, window.scale.y             = glfw.GetWindowContentScale(window.glfw_window)
    window.extent.x, window.extent.y           = glfw.GetWindowSize(window.glfw_window)
    window.draw_extent.x, window.draw_extent.y = glfw.GetFramebufferSize(window.glfw_window)
    window.position.x, window.position.y       = glfw.GetWindowPos(window.glfw_window)
}

@(private)
surface_initialize :: proc(renderer: ^Renderer) {
    if glfw.CreateWindowSurface(renderer.instance, renderer.window.glfw_window, nil, &renderer.surface) != .SUCCESS {
        log.panic("Failed to create window surface!")
    }
}

