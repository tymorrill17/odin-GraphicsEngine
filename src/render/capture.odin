package render

import stbi "vendor:stb/image"
import vk "vendor:vulkan"
import "core:path/filepath"
import "core:time"
import "thirdparty:vma"
import "core:fmt"
import "core:log"
import "core:strings"

CAPTURE_DIR :: #config(CAPTURE_DIR, ".")

capture_screenshot :: proc(renderer: ^Renderer) {
    capture_image := &renderer.capture_image

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = { renderer.screenshot_resolution.x, renderer.screenshot_resolution.y, 1 }

    // Recreate the image if requesting a different size than what already exists
    if capture_image.extent != capture_extent {
        image_recreate(renderer, capture_image, capture_extent)
    }

    // Copy the draw image
    // WARNING: This is okay for now since the renderer is single-threaded, but in the future
    // the draw image should be protected during this step
    // image_transition_now(renderer, capture_image, .TRANSFER_DST_OPTIMAL)
    CommandCtx :: struct { draw_image: ^Image, capture_image: ^Image }
    user_data := CommandCtx{
        draw_image = &renderer.draw_image,
        capture_image = capture_image,
    }
    immediate_command_submit(renderer, &user_data, proc(cmd: vk.CommandBuffer, user_data: rawptr){
        ctx := (^CommandCtx)(user_data)
        draw_image := ctx.draw_image
        capture_image := ctx.capture_image

        image_transition(cmd, capture_image, .TRANSFER_DST_OPTIMAL)
        image_copy(cmd, draw_image^, capture_image^)
        image_transition(cmd, capture_image, .GENERAL)
    })

    right_now := time.now()
    hour, min, sec, nanos := time.precise_clock_from_time(right_now)
    year, month, day := time.date(right_now)
    filename := fmt.aprintf("screenshot-%d-%2d-%2d_%2d:%2d:%2d:%9d.png", year, month, day, hour, min, sec, nanos, allocator=context.temp_allocator)
    complete_filepath, _ := filepath.join({CAPTURE_DIR, filename}, context.temp_allocator)
    complete_filepath_c := strings.clone_to_cstring(complete_filepath, context.temp_allocator)

    NUM_CHANNELS :: 4
    image_data: rawptr
    vma.MapMemory(renderer.allocator, capture_image.allocation, &image_data)

    subresource := vk.ImageSubresource{
        aspectMask = capture_image.aspect_flags,
        mipLevel   = 0,
        arrayLayer = 0,
    }
    subresource_layout: vk.SubresourceLayout
    vk.GetImageSubresourceLayout(renderer.logical_device, capture_image.handle, &subresource, &subresource_layout)

    stbi.write_png(complete_filepath_c, i32(capture_extent.width), i32(capture_extent.height), NUM_CHANNELS, image_data, cast(i32)subresource_layout.rowPitch)
    vma.UnmapMemory(renderer.allocator, capture_image.allocation)
    log.infof("Saved screenshot: %s", filename)

    free_all(context.temp_allocator)
}

