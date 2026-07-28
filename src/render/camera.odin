package render

import "core:math"
import "core:math/linalg"

projection_set_orthographic :: proc(left, right, bottom, top, near, far: f32) -> float4x4 {
    proj: float4x4 = 1 // identity
    proj[0, 0] = 2 / (right - left)
    proj[0, 3] = -(right + left) / (right - left)
    proj[1, 1] = 2 / (bottom - top)
    proj[1, 3] = -(bottom + top) / (bottom - top)
    proj[2, 2] = 1 / (far - near)
    proj[2, 3] = far / (far - near)
    return proj
}

projection_set_perspective :: proc(vertical_fov, aspect_ratio, near, far: f32) -> float4x4 {

    fov_radians := vertical_fov * math.PI / 180
    focal_length := 1 / math.tan(fov_radians * 0.5)
    a := near / (far - near)

    proj: float4x4 = 0 // NOT identity
    proj[0, 0] = focal_length / aspect_ratio
    proj[1, 1] = -focal_length
    proj[2, 2] = a
    proj[3, 2] = -1
    proj[2, 3] = a * far
    return proj
}

view_set_direction :: proc(position, direction, up: float3) -> float4x4 {
    forward := linalg.normalize0(direction)
    right   := linalg.cross(forward, up)
    rel_up  := linalg.cross(right, forward)

    view: float4x4 = 1 // identity
    view[0, 0] = right.x
    view[0, 1] = right.y
    view[0, 2] = right.z
    view[1, 0] = rel_up.x
    view[1, 1] = rel_up.y
    view[1, 2] = rel_up.z
    view[2, 0] = -forward.x
    view[2, 1] = -forward.y
    view[2, 2] = -forward.z

    translate_vec := float4{ -position.x, -position.y, -position.z, 0 }
    translated := view * translate_vec
    for i in 0..<4 {
        view[i, 3] += translated[i]
    }
    return view
}

view_set_target :: proc(position, target, up: float3) -> float4x4 {
   return view_set_direction(position, target - position, up);
}


