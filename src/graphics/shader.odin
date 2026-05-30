package renderer

import vk "vendor:vulkan"

Shader :: struct {
    module: vk.ShaderModule,
    stage:  vk.ShaderStageFlags,
}
