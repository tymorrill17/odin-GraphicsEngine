package renderer

import "base:runtime"
import "core:log"
import "core:c"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"
import vma "../thirdparty/vma"

glob_ctx: runtime.Context

pool_sizes := []PoolSizeRatio {
    {vk.DescriptorType.UNIFORM_BUFFER,         100},
    {vk.DescriptorType.UNIFORM_BUFFER_DYNAMIC, 100},
    {vk.DescriptorType.STORAGE_BUFFER,         100},
    {vk.DescriptorType.COMBINED_IMAGE_SAMPLER, 100},
};

device_features: vk.PhysicalDeviceFeatures
device_features_11 := vk.PhysicalDeviceVulkan11Features{ sType = vk.StructureType.PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
    shaderDrawParameters = true,
}
device_features_12 := vk.PhysicalDeviceVulkan12Features{ sType = vk.StructureType.PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    descriptorIndexing = true,
    bufferDeviceAddress = true,
}
device_features_13 := vk.PhysicalDeviceVulkan13Features{ sType = vk.StructureType.PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    synchronization2 = true,
    dynamicRendering = true,
}

RendererCreateInfo :: struct {
    app_name:           cstring,
    extent:             int2,
    validation_layers:  []cstring,
    device_extensions:  []cstring,
    use_discrete_GPU:   bool
}

Renderer :: struct {
    window:                 Window,
    instance:               vk.Instance,
    debug_messenger:        vk.DebugUtilsMessengerEXT,
    logical_device:         vk.Device,
    physical_device:        vk.PhysicalDevice,
    queues:                 [QueueFamily]vk.Queue,
    queue_indices:          [QueueFamily]u32,
    surface:                vk.SurfaceKHR,
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

renderer_create :: proc(renderer_create_info: RendererCreateInfo) -> Renderer {
    rci := renderer_create_info
    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger
    glob_ctx = context // Save this for the debug messenger callback

    renderer: Renderer
    renderer.window = window_create(rci.extent.x, rci.extent.y, rci.app_name)

    instance_initialize(&renderer, rci.app_name, "OdinRenderer", rci.validation_layers, []cstring{})

    // The window surface needs the instance to be created, so do it now
    surface_initialize(&renderer)
    devices_initialize(&renderer, renderer_create_info.use_discrete_GPU, rci.device_extensions)

    vulkan_allocator_initialize(&renderer)

    swapchain_create(&renderer)

    return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {
    swapchain_destroy(renderer)
    vma.DestroyAllocator(renderer.allocator)
    vk.DestroyDevice(renderer.logical_device, nil)
    vk.DestroySurfaceKHR(renderer.instance, renderer.surface, nil)
    vk.DestroyInstance(renderer.instance, nil)
    window_destroy(&renderer.window)
}

window_should_close :: proc(renderer: Renderer) -> bool {
    return bool(glfw.WindowShouldClose(renderer.window.glfw_window))
}

QueueFamily :: enum {
    graphics,
    present,
}

DeviceQueues :: struct {
    indices:    [QueueFamily]int,
    queues:     [QueueFamily]vk.Queue,
}

@(private)
instance_initialize :: proc(renderer: ^Renderer,
    app_name, engine_name: cstring,
    requested_validation_layers, requested_extensions: []cstring) {

    check_validation_layer_support :: proc(requested_layers: []cstring) -> bool {
        layer_count: u32
        vk.EnumerateInstanceLayerProperties(&layer_count, nil)
        supported_layers := make([]vk.LayerProperties, layer_count)
        vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(supported_layers))
        defer delete(supported_layers)
        check: for requested_layer in requested_layers {
            for &found_layer in supported_layers {
                if requested_layer == cstring(&found_layer.layerName[0]) {
                    continue check
                }
            }
            log.errorf("Layer not supported: %s", requested_layer)
            return false
        }
        return true
    }

    vk.load_proc_addresses_global((rawptr)(glfw.GetInstanceProcAddress))
    assert(vk.CreateInstance != nil, "Vulkan procs not loaded!")

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
        sType               = vk.StructureType.APPLICATION_INFO,
        pApplicationName    = app_name,
        applicationVersion  = vk.MAKE_API_VERSION(1, 0, 0, 0),
        pEngineName         = engine_name,
        engineVersion       = vk.MAKE_API_VERSION(1, 0, 0, 0),
        apiVersion          = instance_version
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
        enabledExtensionCount = u32(len(extensions)),
        ppEnabledExtensionNames = raw_data(extensions),
        // Initialize explicitly first, overwrite if using layers
        enabledLayerCount = validation_layers_enabled ? u32(len(requested_validation_layers)) : 0,
        ppEnabledLayerNames = validation_layers_enabled ? raw_data(requested_validation_layers) : nil,
    }

    if validation_layers_enabled {
        debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT{
            sType           = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = { .VERBOSE, .ERROR },
            messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE },
            pfnUserCallback = vk.ProcDebugUtilsMessengerCallbackEXT(vk_debug_callback)
        }
        instance_create_info.pNext = &debug_create_info
    }

    result := vk.CreateInstance(&instance_create_info, nil, &renderer.instance)
    if result != .SUCCESS {
        log.panic("Failed to create Vulkan instance: ", result)
    }

    log.info("Created Instance")
    vk.load_proc_addresses_instance(renderer.instance)
}

@(private)
get_queue_indices :: proc(renderer: ^Renderer) {
    for &queue in renderer.queue_indices {
        queue = c.UINT32_MAX
    }

    // Get the properties of queue families from the physical device
    queue_family_count: u32 = 0
    vk.GetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &queue_family_count, nil)
    queue_family_properties := make([]vk.QueueFamilyProperties, queue_family_count)
    vk.GetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &queue_family_count, raw_data(queue_family_properties))
    defer delete(queue_family_properties)

    for queue_family, i in queue_family_properties {
        // If the queue is a graphics queue and we haven't already found a graphics queue
        if .GRAPHICS in queue_family.queueFlags && renderer.queue_indices[.graphics] == c.UINT32_MAX {
            renderer.queue_indices[.graphics] = u32(i)
        }

        // The present queue may also be the graphics queue, which is ok
        present_queue_support: b32
        vk.GetPhysicalDeviceSurfaceSupportKHR(renderer.physical_device, u32(i), renderer.surface, &present_queue_support)
        if present_queue_support && renderer.queue_indices[.present] == c.UINT32_MAX {
            renderer.queue_indices[.present] = u32(i)
        }

        // Did we find all of our queues?
		for q in renderer.queue_indices do if q == c.UINT32_MAX do continue;
        break;
    }

    // Make sure we actually found queues
    for q in renderer.queue_indices do if q == c.UINT32_MAX do log.panic("Failed to find device queues!");
}

@(private)
devices_initialize :: proc(renderer: ^Renderer, request_discrete_GPU: bool, requested_extensions: []cstring) {

    select_physical_device(renderer, request_discrete_GPU, requested_extensions)
    get_queue_indices(renderer)

    unique_queues: map[u32]b8
    defer delete(unique_queues)
    for i in renderer.queue_indices {
        unique_queues[i] = true
    }

    priority: f32 = 1.0
    queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(unique_queues))
    defer delete(queue_create_infos)
    for queue_index, _ in unique_queues {
        queue_create_info := vk.DeviceQueueCreateInfo{
            sType               = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex    = u32(queue_index),
            queueCount          = 1,
            pQueuePriorities    = &priority,
        }
        append(&queue_create_infos, queue_create_info)
    }

    version_features := vk.PhysicalDeviceFeatures2{
        sType       = vk.StructureType.PHYSICAL_DEVICE_FEATURES_2,
        features    = device_features,
        pNext       = &device_features_11,
    }
    device_features_11.pNext = &device_features_12
    device_features_12.pNext = &device_features_13

    device_create_info := vk.DeviceCreateInfo{
        sType                   = vk.StructureType.DEVICE_CREATE_INFO,
        pNext                   = &version_features,
        queueCreateInfoCount    = u32(len(queue_create_infos)),
        pQueueCreateInfos       = raw_data(queue_create_infos),
        enabledExtensionCount   = u32(len(requested_extensions)),
        ppEnabledExtensionNames = raw_data(requested_extensions),
    }

    result := vk.CreateDevice(renderer.physical_device, &device_create_info, nil, &renderer.logical_device)
    if result != .SUCCESS {
        log.panic("Failed to create Vulkan device: ", result)
    }

    // Get the actual device queues
    for queue_index, i in renderer.queue_indices {
        vk.GetDeviceQueue(renderer.logical_device, queue_index, 0, &renderer.queues[i])
    }
}

@(private)
select_physical_device :: proc(renderer: ^Renderer, request_discrete_GPU: bool, requested_extensions: []cstring) {
    device_count: u32 = 0
    vk.EnumeratePhysicalDevices(renderer.instance, &device_count, nil)

    if device_count == 0 {
        log.panic("Failed to find a GPU with Vulkan support!")
    }

    devices := make([]vk.PhysicalDevice, device_count)
    vk.EnumeratePhysicalDevices(renderer.instance, &device_count, raw_data(devices))
    defer delete(devices)

    get_device_name :: proc(device: vk.PhysicalDevice) -> string {
        device_properties: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &device_properties);
        return strings.clone(string(cstring(&device_properties.deviceName[0])), context.temp_allocator)
    }

    device_suitable :: proc(device: vk.PhysicalDevice, request_discrete_GPU: bool, requested_extensions: []cstring) -> bool {
        supported_extension_count: u32 = 0
        vk.EnumerateDeviceExtensionProperties(device, nil, &supported_extension_count, nil)
        supported_extensions := make([]vk.ExtensionProperties, supported_extension_count)
        vk.EnumerateDeviceExtensionProperties(device, nil, &supported_extension_count, raw_data(supported_extensions))
        defer delete(supported_extensions)

        check: for extension in requested_extensions {
            for &found_extension in supported_extensions {
                if extension == cstring(&found_extension.extensionName[0]) {
                    continue check
                }
            }
            log.errorf("Layer not supported: %s", extension)
            return false
        }

        properties: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &properties)

        free_all(context.temp_allocator)

        // If we request a discrete GPU and found a discrete GPU, use it
        // If we request an integrated GPU and found one, use it
        return (request_discrete_GPU == (properties.deviceType == vk.PhysicalDeviceType.DISCRETE_GPU))
    }

    for device in devices {
        if device_suitable(device, request_discrete_GPU, requested_extensions) {
            log.infof("Found suitable device: %s\n", get_device_name(device))
            renderer.physical_device = device
            break
        }
    }

    if (renderer.physical_device == nil) do log.panic("No suitable device found!")
}

@(private)
vulkan_allocator_initialize :: proc(renderer: ^Renderer) {
    // First, vma needs to be informed of the vulkan procedures
    vulkan_functions := vma.VulkanFunctions{
        GetPhysicalDeviceProperties       = vk.GetPhysicalDeviceProperties,
        GetPhysicalDeviceMemoryProperties = vk.GetPhysicalDeviceMemoryProperties,
        AllocateMemory                    = vk.AllocateMemory,
        FreeMemory                        = vk.FreeMemory,
        MapMemory                         = vk.MapMemory,
        UnmapMemory                       = vk.UnmapMemory,
        FlushMappedMemoryRanges           = vk.FlushMappedMemoryRanges,
        InvalidateMappedMemoryRanges      = vk.InvalidateMappedMemoryRanges,
        BindBufferMemory                  = vk.BindBufferMemory,
        BindImageMemory                   = vk.BindImageMemory,
        GetBufferMemoryRequirements       = vk.GetBufferMemoryRequirements,
        GetImageMemoryRequirements        = vk.GetImageMemoryRequirements,
        CreateBuffer                      = vk.CreateBuffer,
        DestroyBuffer                     = vk.DestroyBuffer,
        CreateImage                       = vk.CreateImage,
        DestroyImage                      = vk.DestroyImage,
        CmdCopyBuffer                     = vk.CmdCopyBuffer,
    }

    // Now create the allocator, passing in the vulkan function pointers
    allocator_create_info := vma.AllocatorCreateInfo{
        flags               = { .BUFFER_DEVICE_ADDRESS },
        physicalDevice      = renderer.physical_device,
        device              = renderer.logical_device,
        instance            = renderer.instance,
        pVulkanFunctions    = &vulkan_functions,
    }

    if vma.CreateAllocator(&allocator_create_info, &renderer.allocator) != .SUCCESS {
        log.panic("Failed to create Vulkan memory allocator!")
    }
}

@(private)
vk_debug_callback :: proc "system" (
    messageSeverity:   vk.DebugUtilsMessageSeverityFlagsEXT,
    messageType:       vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData:    ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData:        ^rawptr) -> b32 {

    context = glob_ctx
    if .ERROR in messageSeverity {
        log.error("Validation Layer -- ", pCallbackData.pMessage)
    } else if .WARNING in messageSeverity {
        log.warn("Validation Layer -- ", pCallbackData.pMessage)
    } else { // Info
        log.info("Validation Layer -- ", pCallbackData.pMessage)
    }
    return false
}


