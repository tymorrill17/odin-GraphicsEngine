package render

import stbi "vendor:stb/image"
import vk "vendor:vulkan"
import "core:strings"

capture_screenshot :: proc(renderer: ^Renderer, filename: string, size: [2]u32 = 0) {
    capture_image := &renderer.capture_image

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D
    if size == 0 {
        capture_extent = renderer.draw_image.extent
    } else {
        capture_extent = { size.x, size.y, 1 }
    }

    // Recreate the image if requesting a different size than what already exists
    if capture_image.extent != capture_extent {
        image_recreate(renderer, capture_image, capture_extent)
    }

    filename := strings.clone_to_cstring(filename)
    defer delete(filename)

    // capture_buffer := buffer_create(renderer)

    NUM_CHANNELS :: 4
    // capture_image_data := image_copy_to_buffer(renderer, capture_image, capture_buffer)
    // stbi.write_png(filename, i32(capture_extent.width), i32(capture_extent.height), NUM_CHANNELS, capture_image_data, 0)
}

