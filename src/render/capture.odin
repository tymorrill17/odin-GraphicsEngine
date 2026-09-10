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
import "core:sync"
import "core:thread"
import "base:runtime"

CAPTURE_DIR :: #config(CAPTURE_DIR, ".")
NUM_CHANNELS :: 4

Recorder :: struct {
    process:                    os.Process,
    slots:                      []RecorderSlot,
    pipe:                       ^os.File,
    pipe_mutex:                 sync.Mutex,
    pipe_cond:                  sync.Cond,
    framerate:                  i32,
    resolution:                 [2]u32,
    recording:                  bool,
    current_frame_index:        u64,
    atomic_next_frame_index:    u64,
    atomic_pipe_broken:         bool,
}

RecorderSlot :: struct {
    thread:                 ^thread.Thread,
    renderer:               ^Renderer,
    capture_buffer:         Buffer,
    sem_buffer_copied:      sync.Sema,
    sem_buffer_piped:       sync.Sema,
    frame_index:            u64,
    atomic_screenshot:      bool,
    atomic_record:          bool,
    atomic_should_quit:     bool,
}

@(private)
recorder_initialize :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    recorder^ = {
        recording           = false,
        current_frame_index = 0,
        framerate           = renderer.window.glfw_mode.refresh_rate, // By default
        resolution          = { renderer.draw_image.extent.width, renderer.draw_image.extent.height },
        slots               = make([]RecorderSlot, renderer.frames_in_flight),
    }

    buffer_size := image_get_size(renderer.draw_image.extent)
    for &slot in recorder.slots {
        slot.capture_buffer     = buffer_create(renderer, buffer_size, 1, { .TRANSFER_DST }, .GPU_TO_CPU)
        slot.frame_index        = 0
        slot.renderer           = renderer
        slot.atomic_screenshot  = false
        slot.atomic_should_quit = false
        slot.atomic_record      = false
        slot.thread             = thread.create_and_start_with_data(rawptr(&slot), recorder_thread_proc)
    }
}

@(private)
recorder_destroy :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    for &slot in recorder.slots {
        sync.atomic_store(&slot.atomic_should_quit, true)
        sync.sema_post(&slot.sem_buffer_copied)
    }
    sync.cond_broadcast(&recorder.pipe_cond)
    for &slot in recorder.slots {
        thread.destroy(slot.thread)
        buffer_destroy(renderer, &slot.capture_buffer)
    }
    capture_end_recording(renderer)
    delete(recorder.slots)
    recorder^ = {}
}

@(private)
recorder_resize_buffers :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    new_size := image_get_size(renderer.draw_image.extent)
    for &slot in recorder.slots {
        buffer_destroy(renderer, &slot.capture_buffer)
        slot.capture_buffer = buffer_create(renderer, new_size, 1, { .TRANSFER_DST }, .GPU_TO_CPU)
    }
}

@(private)
recorder_thread_proc :: proc(data: rawptr) {
    slot: ^RecorderSlot = cast(^RecorderSlot)data
    renderer := slot.renderer
    recorder := &slot.renderer.recorder

    for !sync.atomic_load(&slot.atomic_should_quit) {
        // First, wait for the render thread to confirm the image has been drawn to and copied to the buffer
        sync.sema_wait(&slot.sem_buffer_copied)

        if sync.atomic_load(&slot.atomic_screenshot) {
            capture_screenshot(renderer, slot)
        }

        if sync.atomic_load(&slot.atomic_record) {
            sync.mutex_lock(&recorder.pipe_mutex)
            for slot.frame_index != sync.atomic_load(&recorder.atomic_next_frame_index) &&
                !sync.atomic_load(&slot.atomic_should_quit) {

                sync.cond_wait(&recorder.pipe_cond, &recorder.pipe_mutex)
            }
            if !sync.atomic_load(&recorder.atomic_pipe_broken) {
                capture_send_recorded_image(renderer, slot)
            }
            sync.atomic_add(&recorder.atomic_next_frame_index, 1)
            sync.mutex_unlock(&recorder.pipe_mutex)
            sync.cond_broadcast(&recorder.pipe_cond)
        }

        // Signal that the render thread may submit another command buffer to overwrite this drawimage
        sync.sema_post(&slot.sem_buffer_piped)
    }
}

@(private)
capture_get_output_filename :: proc(filename: string, extension: string, allocator: runtime.Allocator) -> string {
    right_now := time.now()
    hour, min, sec, nanos := time.precise_clock_from_time(right_now)
    year, month, day := time.date(right_now)
    return fmt.aprintf("%s-%d-%2d-%2d_%2d:%2d:%2d:%9d%s", filename, year, month, day, hour, min, sec, nanos, extension, allocator=allocator)
}

// Map the capture_buffer memory and write the contents to a .png file. capture_buffer must not be in UNKNOWN layout.
// Either transition it before this call or call capture_copy_image()
@(private)
capture_screenshot :: proc(renderer: ^Renderer, slot: ^RecorderSlot) {
    capture_buffer := &slot.capture_buffer
    capture_extent := renderer.draw_image.extent

    filename             := capture_get_output_filename("screenshot", ".png", context.temp_allocator)
    complete_filepath, _ := filepath.join({CAPTURE_DIR, filename}, context.temp_allocator)
    complete_filepath_c  := strings.clone_to_cstring(complete_filepath, context.temp_allocator)

    buffer_map(renderer, capture_buffer)
    stbi.write_png(complete_filepath_c, i32(capture_extent.width), i32(capture_extent.height), NUM_CHANNELS, capture_buffer.data_ptr, 0)
    buffer_unmap(renderer, capture_buffer)
    log.infof("Saved screenshot: %s", filename)
    sync.atomic_store(&slot.atomic_screenshot, false)

    free_all(context.temp_allocator)
}

@(private)
capture_copy_image :: proc(cmd: vk.CommandBuffer, renderer: ^Renderer) {
    draw_image := &renderer.draw_image
    capture_buffer := &renderer.recorder.slots[renderer.frame_index].capture_buffer

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = renderer.draw_image.extent
    recorder_res := vk.Extent3D{ renderer.recorder.resolution.x, renderer.recorder.resolution.y, 1 }

    // Copy the draw image to the capture_buffer buffer
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
    vk.CmdCopyImageToBuffer(cmd, draw_image.handle, draw_image.layout, capture_buffer.handle, 1, &copy_info)
}

// Initialize the ffmpeg process
capture_start_recording :: proc(renderer: ^Renderer) {
    if renderer.recorder.recording do return

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

    sync.atomic_store(&recorder.atomic_next_frame_index, renderer.frame_number)

    log.infof("Began recording: %s", filename)
    free_all(context.temp_allocator)
}

capture_end_recording :: proc(renderer: ^Renderer) {
    if !renderer.recorder.recording do return

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
capture_send_recorded_image :: proc(renderer: ^Renderer, slot: ^RecorderSlot) {
    if !renderer.recorder.recording do return

    recorder := &renderer.recorder
    capture_buffer := &slot.capture_buffer
    capture_extent: vk.Extent3D = renderer.draw_image.extent

    buffer_map(renderer, capture_buffer)

    total_bytes := int(image_get_size(capture_extent))
    image_data_ptr := mem.slice_ptr((^u8)(capture_buffer.data_ptr), total_bytes)

    // Pipe writes go short as soon as the pipe buffer fills, which at 8 MB a frame is
    // every frame, so loop until the whole thing is out.
    for written := 0; written < total_bytes; {
        bytes_written, err := os.write(recorder.pipe, image_data_ptr[written:])
        if err != nil {
            log.errorf("Lost the ffmpeg pipe: %v", err)
            buffer_unmap(renderer, capture_buffer)
            capture_end_recording(renderer)
            return
        }
        written += bytes_written
    }
    buffer_unmap(renderer, capture_buffer)
}

capture_ready_to_send :: proc(recorder: ^Recorder) {
    // Get the next available slot
    slot := &recorder.slots[recorder.current_frame_index % u64(len(recorder.slots))]
    slot.frame_index = recorder.current_frame_index
    sync.atomic_store(&slot.atomic_record, recorder.recording)
    sync.sema_post(&slot.sem_buffer_copied)
}

capture_wait_on_send :: proc(recorder: ^Recorder) {
    slot := &recorder.slots[recorder.current_frame_index % u64(len(recorder.slots))]
    slot.frame_index = recorder.current_frame_index
    sync.sema_wait(&slot.sem_buffer_piped)
}

capture_request_screenshot :: proc(renderer: ^Renderer) {
    recorder := &renderer.recorder
    slot := &recorder.slots[recorder.current_frame_index % u64(len(recorder.slots))]
    sync.atomic_store(&slot.atomic_screenshot, true)
}

