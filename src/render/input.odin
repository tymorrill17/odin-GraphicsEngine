package render

import "vendor:glfw"
import "core:math/linalg"
import "thirdparty:imgui"

InputKey :: enum i32 {
    left   = glfw.MOUSE_BUTTON_LEFT,
    right  = glfw.MOUSE_BUTTON_RIGHT,
    middle = glfw.MOUSE_BUTTON_MIDDLE,
}

KeyState :: struct {
    down:       bool, // Held down
    pressed:    bool, // Pressed this frame
    released:   bool, // Release this frame
}

Input :: struct {
    mouse_position:     float2, // Mouse position in window coordinates. Origin at top left
    mouse_delta:        float2, // Change in window coordinates since the last frame
    mouse_ndc:          float2, // Cursor position in clip space: [-1, 1]
    mouse_captured:     bool,

    key_states:         [InputKey]KeyState,
}

// Called at the beginning of every frame, after events have been polled
@(private)
input_update :: proc(renderer: ^Renderer) {
    input       := &renderer.input
    glfw_window := renderer.window.glfw_window

    // Get the mouse updates
    x, y := glfw.GetCursorPos(glfw_window)
    position := float2{ f32(x), f32(y) }
    input.mouse_delta    = position - input.mouse_position
    input.mouse_position = position
    input.mouse_ndc = {
        2 * (position.x / f32(renderer.window.extent.x)) - 1,
        2 * (position.y / f32(renderer.window.extent.y)) - 1,
    }
    // TODO: potentially include mouse leaving the window or leaving focus here
    input.mouse_captured = !imgui.GetIO().WantCaptureMouse

    // Get all button states
    for key in InputKey {
        down  := glfw.GetMouseButton(glfw_window, i32(key)) == glfw.PRESS
        input.key_states[key].pressed  = down && !input.key_states[key].down
        input.key_states[key].released = !down && input.key_states[key].down
        input.key_states[key].down     = down
    }
}

mouse_down :: proc(input: ^Input, key: InputKey) -> bool {
    return input.key_states[key].down
}

mouse_pressed :: proc(input: ^Input, key: InputKey) -> bool {
    return input.key_states[key].pressed
}

mouse_released :: proc(input: ^Input, key: InputKey) -> bool {
    return input.key_states[key].released
}

// Project the cursor into world space using the inverse viewproj matrix
mouse_world_position :: proc(input: ^Input, inv_viewproj: float4x4, ndc_depth: f32 = 0) -> float3 {
    clip  := float4{ input.mouse_ndc.x, input.mouse_ndc.y, ndc_depth, 1 }
    world := inv_viewproj * clip
    if world.w != 0 do world /= world.w
    return world.xyz
}

mouse_world_position_from_viewproj :: proc(input: ^Input, viewproj: float4x4, ndc_depth: f32 = 0) -> float3 {
    return mouse_world_position(input, linalg.inverse(viewproj), ndc_depth)
}
