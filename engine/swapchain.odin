package renderer

import "core:c"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

Swapchain :: struct {
    handle:             vk.SwapchainKHR,
    images:             []vk.Image,
    image_index:        u32,
    image_format:       vk.Format,
    extent:             vk.Extent2D,
    n_swapchain_images: u32,
}

swapchain_recreate :: proc(renderer: ^Renderer) {
    vk.DeviceWaitIdle(renderer.logical_device)
    image_index: u32 = renderer.swapchain.image_index
    swapchain_destroy(renderer)
    swapchain_create(renderer)
    renderer.swapchain.image_index = image_index
    renderer.window.resized = false
}

swapchain_create :: proc(renderer: ^Renderer) {
    capabilities: vk.SurfaceCapabilitiesKHR
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(renderer.physical_device, renderer.surface, &capabilities)

    surface_format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(renderer.physical_device, renderer.surface, &surface_format_count, nil)
    assert(surface_format_count > 0)
    surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count)
    defer delete(surface_formats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(renderer.physical_device, renderer.surface, &surface_format_count, raw_data(surface_formats))

    present_mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(renderer.physical_device, renderer.surface, &present_mode_count, nil)
    assert(present_mode_count > 0)
    present_modes := make([]vk.PresentModeKHR, present_mode_count)
    defer delete(present_modes)
    vk.GetPhysicalDeviceSurfacePresentModesKHR(renderer.physical_device, renderer.surface, &present_mode_count, raw_data(present_modes))

    renderer.swapchain.image_index = 0

    // Set the defaults first
    surface_format: vk.SurfaceFormatKHR = surface_formats[0]
    present_mode: vk.PresentModeKHR = vk.PresentModeKHR.FIFO
    for format in surface_formats {
        if format.format == vk.Format.R8G8B8A8_UNORM &&
            format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
            surface_format = format
            break
        }
    }
    for mode in present_modes {
        if mode == vk.PresentModeKHR.MAILBOX {
            present_mode = mode
            break
        }
    }

    // An extent of size UINT32_MAX means the window resolution should be used
    if capabilities.currentExtent.width != c.UINT32_MAX {
        renderer.swapchain.extent = capabilities.currentExtent
    } else {
        renderer.swapchain.extent = vk.Extent2D{ u32(renderer.window.draw_extent.x), u32(renderer.window.draw_extent.y) }
        // Truncate the extent to within the surface capabilities
        renderer.swapchain.extent.width = math.max(capabilities.minImageExtent.width,
            math.min(capabilities.maxImageExtent.width, renderer.swapchain.extent.width))
        renderer.swapchain.extent.height = math.max(capabilities.minImageExtent.height,
            math.min(capabilities.maxImageExtent.height, renderer.swapchain.extent.height))
    }

    renderer.swapchain.image_format = surface_format.format

    renderer.swapchain.n_swapchain_images = capabilities.minImageCount + 1
    if (capabilities.maxImageCount > 0 &&
        renderer.swapchain.n_swapchain_images > capabilities.maxImageCount) {

        renderer.swapchain.n_swapchain_images = capabilities.maxImageCount
    }

    swapchain_create_info := vk.SwapchainCreateInfoKHR{
        sType               = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        surface             = renderer.surface,
        minImageCount       = renderer.swapchain.n_swapchain_images,
        imageFormat         = renderer.swapchain.image_format,
        imageColorSpace     = surface_format.colorSpace,
        imageExtent         = renderer.swapchain.extent,
        imageArrayLayers    = 1,
        imageUsage          = { .TRANSFER_DST, .COLOR_ATTACHMENT },
        preTransform        = capabilities.currentTransform,
        compositeAlpha      = { .OPAQUE },
        presentMode         = present_mode,
        clipped             = true,
    }

    // Exclusive mode is faster when the graphics and present queue are the same
    if renderer.queue_indices[.graphics] == renderer.queue_indices[.present] {
        swapchain_create_info.imageSharingMode      = vk.SharingMode(.EXCLUSIVE)
        swapchain_create_info.queueFamilyIndexCount = 0
        swapchain_create_info.pQueueFamilyIndices   = nil
    } else {
        swapchain_create_info.imageSharingMode      = vk.SharingMode(.CONCURRENT)
        swapchain_create_info.queueFamilyIndexCount = 2
        swapchain_create_info.pQueueFamilyIndices   = raw_data(&renderer.queue_indices)
    }

    if vk.CreateSwapchainKHR(renderer.logical_device, &swapchain_create_info, nil, &renderer.swapchain.handle) != .SUCCESS {
        log.panic("Failed to create swapchain!")
    }

    renderer.swapchain.images = make([]vk.Image, renderer.swapchain.n_swapchain_images)
    vk.GetSwapchainImagesKHR(renderer.logical_device, renderer.swapchain.handle, &renderer.swapchain.n_swapchain_images, raw_data(renderer.swapchain.images))
}

swapchain_destroy :: proc(renderer: ^Renderer) {
    delete(renderer.swapchain.images)
    vk.DestroySwapchainKHR(renderer.logical_device, renderer.swapchain.handle, nil)
}
