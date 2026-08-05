package render

import "core:time"

Timer :: struct {
    last_tick:   time.Tick, // Very first tick
    frame_time:     f32, // Seconds since last frame
    fps:            f32, // Smoothed frame_time
    avg_frame_time: f32, // Smoothed frames-per-second
    smoothing:      f32, // Factor by which to smooth fps and avg frame time
}

timer_create :: proc(fps_smoothing: f32 = 0.9) -> Timer {
    return Timer{
        last_tick = time.tick_now(),
        smoothing = fps_smoothing,
    }
}

// Call at beginning of frame. Updates frame_time, fps
timer_update :: proc(timer: ^Timer) {
    now := time.tick_now()
    timer.frame_time = f32(time.duration_seconds(time.tick_diff(timer.last_tick, now)))

    if timer.frame_time > 0 {
        instant_fps := 1.0 / timer.frame_time
        timer.fps = timer.fps * timer.smoothing + instant_fps * (1 - timer.smoothing)
        timer.avg_frame_time = timer.avg_frame_time * timer.smoothing + timer.frame_time * (1 - timer.smoothing)
    }

    timer.last_tick = now
}

