package render

import stbi "vendor:stb/image"
import vk "vendor:vulkan"
import "core:path/filepath"
import "core:time"
import "core:mem"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:os"
import "base:runtime"

CAPTURE_DIR :: #config(CAPTURE_DIR, ".")
NUM_CHANNELS :: 4

Recorder :: struct {
    process:    os.Process,
    pipe:       ^os.File,
    framerate:  i32,
    recording:  bool,
    resolution: [2]u32,
}

@(private)
capture_get_output_filename :: proc(filename: string, extension: string, allocator: runtime.Allocator) -> string {
    right_now := time.now()
    hour, min, sec, nanos := time.precise_clock_from_time(right_now)
    year, month, day := time.date(right_now)
    return fmt.aprintf("%s-%d-%2d-%2d_%2d:%2d:%2d:%9d%s", filename, year, month, day, hour, min, sec, nanos, extension, allocator=allocator)
}

// Map the capture_image memory and write the contents to a .png file. capture_image must not be in UNKNOWN layout.
// Either transition it before this call or call capture_copy_image()
capture_screenshot :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed do return

    capture_image := &renderer.capture_image
    capture_extent := renderer.draw_image.extent

    filename             := capture_get_output_filename("screenshot", ".png", context.temp_allocator)
    complete_filepath, _ := filepath.join({CAPTURE_DIR, filename}, context.temp_allocator)
    complete_filepath_c  := strings.clone_to_cstring(complete_filepath, context.temp_allocator)

    buffer_map(renderer, capture_image)
    stbi.write_png(complete_filepath_c, i32(capture_extent.width), i32(capture_extent.height), NUM_CHANNELS, capture_image.data_ptr, 0)
    buffer_unmap(renderer, capture_image)
    log.infof("Saved screenshot: %s", filename)
    renderer.screenshot_requested = false

    free_all(context.temp_allocator)
}

@(private)
capture_copy_image :: proc(cmd: vk.CommandBuffer, renderer: ^Renderer) {
    draw_image := &renderer.draw_image
    capture_image := &renderer.capture_image

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = renderer.draw_image.extent
    recorder_res := vk.Extent3D{ renderer.recorder.resolution.x, renderer.recorder.resolution.y, 1 }

    // Copy the draw image to the capture_image buffer
    copy_info := vk.BufferImageCopy{
        bufferOffset        = 0,
        bufferRowLength     = 0,
        bufferImageHeight   = 0,
        imageExtent         = draw_image.extent,
        imageSubresource    = {
            aspectMask  = draw_image.aspect_flags,
            mipLevel    = 0,
            layerCount  = 1,
        },
    }
    vk.CmdCopyImageToBuffer(cmd, draw_image.handle, draw_image.layout, capture_image.handle, 1, &copy_info)
}
// Copies the draw image to the capture_image immediately
@(private)
capture_copy_image_now :: proc(renderer: ^Renderer) {
    draw_image := &renderer.draw_image
    capture_image := &renderer.capture_image

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = renderer.draw_image.extent
    recorder_res := vk.Extent3D{ renderer.recorder.resolution.x, renderer.recorder.resolution.y, 1 }
    // Recreate the image if requesting a different size than what already exists

    if capture_extent != recorder_res {
        if renderer.recorder.recording do capture_end_recording(renderer)
        buffer_destroy(renderer, capture_image)
        capture_image^ = buffer_create(renderer, image_get_size(capture_extent), 1, { .TRANSFER_DST }, .GPU_TO_CPU)
    }

    // Copy the draw image to the capture_image buffer
    CommandCtx :: struct{ draw_image: Image, capture_image: Buffer}
    copy_command_ctx := CommandCtx{
        draw_image = draw_image^,
        capture_image = capture_image^,
    }
    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        draw_image := ctx.draw_image
        capture_image := ctx.capture_image
        copy_info := vk.BufferImageCopy{
            bufferOffset        = 0,
            bufferRowLength     = 0,
            bufferImageHeight   = 0,
            imageExtent         = draw_image.extent,
            imageSubresource    = {
                aspectMask  = draw_image.aspect_flags,
                mipLevel    = 0,
                layerCount  = 1,
            },
        }
        vk.CmdCopyImageToBuffer(cmd, draw_image.handle, draw_image.layout, capture_image.handle, 1, &copy_info)
    })

}

// Initialize the ffmpeg process
capture_start_recording :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed || renderer.recorder.recording do return

    renderer.recorder.resolution = { renderer.draw_image.extent.width, renderer.draw_image.extent.height }

    recorder := &renderer.recorder
    resolution := fmt.aprintf("%dx%d", renderer.recorder.resolution.x, renderer.recorder.resolution.y, allocator=context.temp_allocator)
    framerate  := fmt.aprintf("%d", recorder.framerate, allocator=context.temp_allocator)

    filename := capture_get_output_filename("recording", ".mp4", context.temp_allocator)

    args := []string {
        "ffmpeg",
        "-loglevel", "info",
        "-y",

        "-f", "rawvideo",
        "-pix_fmt", "rgba",
        "-s", resolution,
        "-r", framerate,
        "-i", "-",

        "-c:v", "libx264",
        "-vb", "2500k",
        "-c:a", "aac",
        "-ab", "200k",
        "-pix_fmt", "yuv420p",
        filename,
    }

    read_end, write_end, pipe_err := os.pipe()
    if pipe_err != nil {
        log.error("Failed to create pipes: %v!", pipe_err)
        return
    }

    process, process_err := os.process_start(os.Process_Desc{
        working_dir = CAPTURE_DIR,
        command     = args,
        stdin       = read_end,
        stdout      = os.stdout,
        stderr      = os.stderr,
    })
    if process_err != nil {
        log.errorf("Failed to start ffmpeg process: %v!", process_err)
        os.close(read_end)
        os.close(write_end)
        return
    }

    os.close(read_end) // Need to close the read end or else we will wait on process forever
    recorder.process   = process
    recorder.pipe      = write_end
    renderer.recorder.recording = true

    log.infof("Began recording: %s", filename)
    free_all(context.temp_allocator)
}

capture_end_recording :: proc(renderer: ^Renderer) {
    if !renderer.recorder.recording || !renderer.capturing_primed do return

    recorder := &renderer.recorder
    renderer.recorder.recording = false

    os.close(recorder.pipe)
    recorder.pipe = nil

    // wait must be after the close, or this deadlocks. process_wait also releases the process handle
    state, err := os.process_wait(recorder.process)
    if err != nil {
        log.errorf("Failed to wait on ffmpeg: %v", err)
    } else if !state.success {
        log.errorf("ffmpeg exited with code %d", state.exit_code)
    }

    recorder.pipe = nil
    recorder.process = {}
    log.infof("Recording Ended.")
}

@(private)
capture_send_recorded_image :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed do return

    recorder := &renderer.recorder
    capture_image := &renderer.capture_image
    capture_extent: vk.Extent3D = renderer.draw_image.extent

    buffer_map(renderer, capture_image)

    total_bytes := int(image_get_size(capture_extent))
    image_data_ptr := mem.slice_ptr((^u8)(capture_image.data_ptr), total_bytes)

    // Pipe writes go short as soon as the pipe buffer fills, which at 8 MB a frame is
    // every frame, so loop until the whole thing is out.
    for written := 0; written < total_bytes; {
        bytes_written, err := os.write(recorder.pipe, image_data_ptr[written:])
        if err != nil {
            log.errorf("Lost the ffmpeg pipe: %v", err)
            capture_end_recording(renderer)
            return
        }
        written += bytes_written
    }
    buffer_unmap(renderer, capture_image)
}
