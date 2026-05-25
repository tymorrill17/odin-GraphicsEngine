package renderer

import "base:runtime"
import "core:log"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"
import vma "shared:vma"

glob_ctx: runtime.Context

Renderer :: struct {
    window:                 Window,
    instance:               vk.Instance,
    debug_messenger:        vk.DebugUtilsMessengerEXT,
    device:                 Device,
    allocator:              vma.Allocator,
    swapchain:              Swapchain,
    pipeline_builder:       PipelineBuilder,
    //draw_image:           AllocatedImage,
    //depth_image:          AllocatedImage,
    command_pool:           vk.CommandPool,
    frame_commands:         []vk.CommandBuffer,
    immediate_command:      vk.CommandBuffer,
    descriptor_builder:     DescriptorBuilder,
    //shader_manager:       ShaderManager,

    frame_acquired_image:   []vk.Semaphore, // Semaphore to let the GPU know the swapchain image has been acquired
    frame_render_fence:     []vk.Fence, // Lets the GPU know that the CPU is done issuing rendering commands

    frame_number:           u64,
    frame_index:            u32,
    frames_in_flight:       u32,

    render_scale:           f32,
}

renderer_create :: proc(app_name: string, width, height: i32, validation_layers, device_extensions: []cstring) -> Renderer {
    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger
    glob_ctx = context // Save this for the debug messenger callback

    renderer: Renderer
    renderer.window = window_create(width, height, app_name)

    vk.load_proc_addresses_global((rawptr)(glfw.GetInstanceProcAddress))
    assert(vk.CreateInstance != nil, "Vulkan procs not loaded!")

    renderer.instance = instance_create(app_name, "OdinRenderer", validation_layers, []cstring{})
    log.info("Created Instance")
    vk.load_proc_addresses_instance(renderer.instance)

    return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {

    vk.DestroyInstance(renderer.instance, nil)
    window_destroy(&renderer.window)
}

window_should_close :: proc(renderer: Renderer) -> bool {
    return cast(bool)glfw.WindowShouldClose(renderer.window.glfw_window)
}

pool_sizes := []PoolSizeRatio {
    {vk.DescriptorType.UNIFORM_BUFFER,         100},
    {vk.DescriptorType.UNIFORM_BUFFER_DYNAMIC, 100},
    {vk.DescriptorType.STORAGE_BUFFER,         100},
    {vk.DescriptorType.COMBINED_IMAGE_SAMPLER, 100},
};

Device :: struct {

}

Swapchain :: struct {

}

@(private)
instance_create :: proc(app_name, engine_name: string,
    requested_validation_layers, requested_extensions: []cstring) -> vk.Instance {

    // If we pass in validation layers, we know we are using them
    validation_layers_enabled := false
    when ODIN_DEBUG {
        validation_layers_enabled = true
    }

    if validation_layers_enabled && !check_validation_layer_support(requested_validation_layers) {
        log.error("One or more of requested validation layers not supported.")
    }

    instance_version: u32
    vk.EnumerateInstanceVersion(&instance_version)

    app_info := vk.ApplicationInfo{
        sType = vk.StructureType.APPLICATION_INFO,
        pApplicationName = strings.clone_to_cstring(app_name, context.temp_allocator),
        applicationVersion = vk.MAKE_API_VERSION(1, 0, 0, 0),
        pEngineName = strings.clone_to_cstring(engine_name, context.temp_allocator),
        engineVersion = vk.MAKE_API_VERSION(1, 0, 0, 0),
        apiVersion = instance_version
    }

    // This will return required extensions for the windowing API and validation layers, if used
    extensions := get_required_vulkan_extensions(validation_layers_enabled)
    for ext in requested_extensions {
        append(&extensions, ext)
    }
    defer delete(extensions)

    instance_create_info := vk.InstanceCreateInfo{
        sType = vk.StructureType.INSTANCE_CREATE_INFO,
        pApplicationInfo = &app_info,
        enabledExtensionCount = cast(u32)len(extensions),
        ppEnabledExtensionNames = raw_data(extensions),
        // Initialize explicitly first, overwrite if using layers
        enabledLayerCount = validation_layers_enabled ? cast(u32)len(requested_validation_layers) : 0,
        ppEnabledLayerNames = validation_layers_enabled ? raw_data(requested_validation_layers) : nil,
    }

    debug_create_info: vk.DebugUtilsMessengerCreateInfoEXT
    if validation_layers_enabled {
        debug_create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            sType           = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = { .VERBOSE, .ERROR },
            messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE },
            pfnUserCallback = cast(vk.ProcDebugUtilsMessengerCallbackEXT)vk_debug_callback
        }
        instance_create_info.pNext = &debug_create_info
    }

    instance: vk.Instance
    result := vk.CreateInstance(&instance_create_info, nil, &instance)
    if result != .SUCCESS {
        log.panic("Failed to create Vulkan instance: ", result)
    }

    return instance
}

@(private)
check_validation_layer_support :: proc(requested_layers: []cstring) -> bool {
    layer_count: u32
    vk.EnumerateInstanceLayerProperties(&layer_count, nil)
    supported_layers := make([]vk.LayerProperties, layer_count)
    vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(supported_layers))

    check: for requested_layer in requested_layers {
        for &found_layer in supported_layers {
            if requested_layer == strings.clone_to_cstring(string(found_layer.layerName[:]), context.temp_allocator) {
                continue check
            }
        }
        log.errorf("Layer not supported: %s", requested_layer)
        return false
    }

    return true
}

@(private)
vk_debug_callback :: proc "system" (
    messageSeverity:   vk.DebugUtilsMessageSeverityFlagsEXT,
    messageType:       vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData:    ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData:        ^rawptr) -> b32 {

    context = glob_ctx
    log.error("Validation Layer -- ", pCallbackData.pMessage)
    return false
}


