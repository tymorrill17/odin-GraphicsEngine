package renderer

import vk "vendor:vulkan"
import "core:log"

MAX_SETS_PER_POOL :: 4096

PoolSizeRatio :: struct {
    type:  vk.DescriptorType,
    ratio: f32
}

// Descriptor Layout Builder

DescriptorLayoutBuilder :: [dynamic]vk.DescriptorSetLayoutBinding

descriptor_layout_builder_create :: proc() -> DescriptorLayoutBuilder {
    descriptor_layout_builder := make(DescriptorLayoutBuilder)
    return descriptor_layout_builder
}

descriptor_layout_builder_destroy :: proc(descriptor_layout_builder: ^DescriptorLayoutBuilder) {
    delete(descriptor_layout_builder^)
    descriptor_layout_builder^ = nil
}

descriptor_layout_builder_add_binding :: proc(descriptor_layout_builder: ^[dynamic]vk.DescriptorSetLayoutBinding, binding: u32, descriptor_type: vk.DescriptorType, shader_stage: vk.ShaderStageFlags) {
    new_binding := vk.DescriptorSetLayoutBinding{
		binding         = binding,
		descriptorType  = descriptor_type,
		descriptorCount = 1,
		stageFlags      = shader_stage
	}

    append(descriptor_layout_builder, new_binding)
}

descriptor_layout_builder_build :: proc(descriptor_layout_builder: ^[dynamic]vk.DescriptorSetLayoutBinding, renderer: ^Renderer) -> vk.DescriptorSetLayout {
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

// Descriptor Allocator


// TODO: consider having a global descriptor pool and a per-frame one?
// Dynamic descriptor pool management structure
DescriptorAllocator :: struct {
    pool_size_ratios:   [dynamic]PoolSizeRatio,
    full_pools:         [dynamic]vk.DescriptorPool,
    open_pools:         [dynamic]vk.DescriptorPool,
    sets_per_pool:      uint,
    pool_flags:         vk.DescriptorPoolCreateFlags,
}

@(private)
descriptor_allocator_initialize :: proc(renderer: ^Renderer, initial_sets: uint, pool_size_ratios: []PoolSizeRatio, flags: vk.DescriptorPoolCreateFlags = {}) {
    renderer.descriptor_allocator.pool_size_ratios  = make([dynamic]PoolSizeRatio, len(pool_size_ratios))
    renderer.descriptor_allocator.full_pools        = make([dynamic]vk.DescriptorPool)
    renderer.descriptor_allocator.open_pools        = make([dynamic]vk.DescriptorPool)

    for ratio in pool_size_ratios {
        append(&renderer.descriptor_allocator.pool_size_ratios, ratio)
    }
    renderer.descriptor_allocator.pool_flags    = flags
    renderer.descriptor_allocator.sets_per_pool = uint(f32(initial_sets) * 1.5) // Next pool creation, allow for more sets

    descriptor_allocator_expand_open_pools(renderer, initial_sets, pool_size_ratios)
}

@(private)
descriptor_allocator_destroy :: proc(renderer: ^Renderer) {
    for pool in renderer.descriptor_allocator.open_pools {
        vk.DestroyDescriptorPool(renderer.logical_device, pool, nil)
    }
    delete(renderer.descriptor_allocator.open_pools)
    for pool in renderer.descriptor_allocator.full_pools {
        vk.DestroyDescriptorPool(renderer.logical_device, pool, nil)
    }
    delete(renderer.descriptor_allocator.full_pools)
    delete(renderer.descriptor_allocator.pool_size_ratios)
    renderer.descriptor_allocator = {}
}

@(private)
descriptor_allocator_reset_all :: proc(renderer: ^Renderer) {
    for pool in renderer.descriptor_allocator.open_pools {
        vk.ResetDescriptorPool(renderer.logical_device, pool, nil)
    }
    for pool in renderer.descriptor_allocator.full_pools {
        vk.ResetDescriptorPool(renderer.logical_device, pool, nil)
        append(&renderer.descriptor_allocator.open_pools, pool)
    }
    clear(&renderer.descriptor_allocator.full_pools)
}

@(private="file")
descriptor_allocator_expand_open_pools :: proc(renderer: ^Renderer, set_count: uint, pool_size_ratios: []PoolSizeRatio) {
    pool_sizes: []vk.DescriptorPoolSize = make([]vk.DescriptorPoolSize, len(pool_size_ratios))
    for ratio, i in pool_size_ratios {
        pool_sizes[i] = vk.DescriptorPoolSize{
            type            = ratio.type,
            descriptorCount = u32(ratio.ratio * f32(set_count)),
        }
    }

    pool_info := vk.DescriptorPoolCreateInfo{
        sType           = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
        flags           = renderer.descriptor_allocator.pool_flags,
        maxSets         = u32(set_count),
        poolSizeCount   = u32(len(pool_sizes)),
        pPoolSizes      = raw_data(pool_sizes)
    }

    pool: vk.DescriptorPool
    if vk.CreateDescriptorPool(renderer.logical_device, &pool_info, nil, &pool) != .SUCCESS {
        log.panic("Failed to expand descriptor allocator!")
    }

    append(&renderer.descriptor_allocator.open_pools, pool)
}

@(private)
descriptor_allocator_allocate_set :: proc(renderer: ^Renderer, layouts: []vk.DescriptorSetLayout) -> vk.DescriptorSet {

    get_open_pool :: proc(renderer: ^Renderer) -> vk.DescriptorPool {
        if len(renderer.descriptor_allocator.open_pools) == 0 { // There are no open pools, need to make one
            descriptor_allocator_expand_open_pools(renderer, renderer.descriptor_allocator.sets_per_pool, renderer.descriptor_allocator.pool_size_ratios[:])
            renderer.descriptor_allocator.sets_per_pool = uint(f32(renderer.descriptor_allocator.sets_per_pool) * 1.5)
            if renderer.descriptor_allocator.sets_per_pool > MAX_SETS_PER_POOL {
                renderer.descriptor_allocator.sets_per_pool = MAX_SETS_PER_POOL
            }
        }
        return renderer.descriptor_allocator.open_pools[len(renderer.descriptor_allocator.open_pools) - 1]
    }

    pool_to_use := get_open_pool(renderer)
    alloc_info := vk.DescriptorSetAllocateInfo{
        sType               = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool      = pool_to_use,
        descriptorSetCount  = u32(len(layouts)),
        pSetLayouts         = raw_data(layouts),
    }

    new_set: vk.DescriptorSet
    result: vk.Result
    if result = vk.AllocateDescriptorSets(renderer.logical_device, &alloc_info, &new_set); result != .SUCCESS {
        if result == .ERROR_OUT_OF_POOL_MEMORY || result == .ERROR_FRAGMENTED_POOL {
            // Then try again with a new pool
            append(&renderer.descriptor_allocator.full_pools, pool_to_use)
            pop(&renderer.descriptor_allocator.open_pools)
            pool_to_use = get_open_pool(renderer)
            alloc_info.descriptorPool = pool_to_use
            result = vk.AllocateDescriptorSets(renderer.logical_device, &alloc_info, &new_set)
        }
        if result != .SUCCESS {
            log.panic("Failed to allocate descriptor set!")
        }
    }

    return new_set
}





