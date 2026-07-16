package renderer

import vk "vendor:vulkan"
import "core:log"

PoolSizeRatio :: struct {
    type:  vk.DescriptorType,
    ratio: f32
}

descriptor_layout_add_binding :: proc(descriptor_layout_builder: ^[dynamic]vk.DescriptorSetLayoutBinding, binding: u32, descriptor_type: vk.DescriptorType, shader_stage: vk.ShaderStageFlags) {
    new_binding := vk.DescriptorSetLayoutBinding{
		binding         = binding,
		descriptorType  = descriptor_type,
		descriptorCount = 1,
		stageFlags      = shader_stage
	}

    append(descriptor_layout_builder, new_binding)
}

descriptor_layout_build :: proc(renderer: ^Renderer, descriptor_layout_builder: ^[dynamic]vk.DescriptorSetLayoutBinding) -> vk.DescriptorSetLayout {
    set_layout: vk.DescriptorSetLayout

	descriptor_set_layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType           = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext           = nil,
		flags           = { },
		bindingCount    = cast(u32)len(descriptor_layout_builder),
		pBindings       = raw_data(descriptor_layout_builder[:]),
	};

    if vk.CreateDescriptorSetLayout(renderer.logical_device, &descriptor_set_layout_info, nil, &set_layout) != .SUCCESS {
        log.panic("Failed to create descriptor set layout!")
    }

    return set_layout
}

