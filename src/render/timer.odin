package render

import "core:time"

Timer :: struct {
    last_tick:      time.Tick,
    frame_time:     f32,        // Seconds since last frame
    fps:            f32,        // Smoothed frame_time
    avg_frame_time: f32,        // Smoothed frames-per-second
    smoothing:      f32,        // Factor by which to smooth fps and avg frame time
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

// do an accurate_sleep to make up the remainder of the time left between frames in order to limit the framerate
timer_limit_framerate :: proc(timer: ^Timer, target_fps: i32) {
    if target_fps <= 0 do return

    target_frame_time := 1.0 / f64(target_fps)
    remaining := target_frame_time - time.duration_seconds(time.tick_since(timer.last_tick))
    if remaining > 0 {
        time.accurate_sleep(time.Duration(remaining * f64(time.Second)))
    }
}

// Just get the time elapsed since last_tick. Don't update the timer info
timer_time_since_last_tick :: proc(timer: Timer) -> f32 {
    now := time.tick_now()
    return f32(time.duration_seconds(time.tick_diff(timer.last_tick, now)))
}

