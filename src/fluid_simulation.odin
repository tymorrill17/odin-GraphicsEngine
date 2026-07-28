package main

import "render"
import "core:math"

ParticleConfig :: struct {
    spacing:        f32,
    radius:         f32,
    n_particles:    u32,
    default_color:  render.float4,
}

MAX_PARTICLES :: 5000000

FluidSimState :: struct {
    system:             ^render.CPUParticleSystem,
    config:             ^ParticleConfig,

    // Particle properties
    density:            []f32,
    acceleration:       []render.float3,
    velocity:           []render.float3,
    position:           []render.float3,
    color:              []render.float4,

    // Pertaining to spatial hashing
    particle_index:     []u32,
    start_index:        []u32,
    spatial_lookup:     []u32,

    simulation_started: bool,
}

fluidsim_get_material :: proc(renderer: ^render.Renderer) -> render.MaterialInstance{

    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "particle.slang.spv")
    defer render.shader_module_destroy(renderer, shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .VERTEX }, "billboard")
    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .FRAGMENT }, "render_quad_as_circle")
    render.pipeline_cfg_set_input_topology(&pipeline_cfg, .TRIANGLE_LIST)
    render.pipeline_cfg_set_polygon_mode(&pipeline_cfg, .FILL)
    render.pipeline_cfg_set_cull_mode(&pipeline_cfg, {}, .CLOCKWISE)
    render.pipeline_cfg_set_multisampling(&pipeline_cfg, { ._1 })
    render.pipeline_cfg_set_blending(&pipeline_cfg, .ALPHA)
    render.pipeline_cfg_set_color_attachment_format(&pipeline_cfg, renderer.draw_image.format)
    render.pipeline_cfg_set_depth_attachment_format(&pipeline_cfg, renderer.depth_image.format)
    render.pipeline_cfg_set_depth_test(&pipeline_cfg, .GREATER_OR_EQUAL)
    render.pipeline_cfg_add_push_constant_range(&pipeline_cfg, { .VERTEX }, size_of(render.DrawPushConstants))

    for layout in renderer.scene_descriptor_layouts {
        render.pipeline_cfg_add_descriptor(&pipeline_cfg, layout)
    }

    material: render.MaterialInstance
    material.pass_type = .transparent

    // Material descriptor set creation

    // material_descriptor_layout: vk.DescriptorSetLayout
    // render.pipeline_cfg_add_descriptor(&pipeline_cfg, material_descriptor_layout)
    // material_descriptor: vk.DescriptorSet
    // material.descriptor = material_descriptor

    material.pipeline = render.pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    return material
}

fluidsim_state_create :: proc(system: ^render.CPUParticleSystem, config: ^ParticleConfig) -> render.ParticleMotion {
    state := new(FluidSimState)
    state.system            = system
    state.config            = config
    state.color             = make([]render.float4, system.max_particles)
    state.position          = make([]render.float3, system.max_particles)
    state.velocity          = make([]render.float3, system.max_particles)
    state.acceleration      = make([]render.float3, system.max_particles)
    state.density           = make([]f32, system.max_particles)
    state.particle_index    = make([]u32, system.max_particles)
    state.spatial_lookup    = make([]u32, system.max_particles)
    state.start_index       = make([]u32, system.max_particles)

    return render.ParticleMotion{
        data    = state,
        update  = fluidsim_update_particles,
        destroy = fluidsim_state_destroy,
    }
}

fluidsim_state_destroy :: proc(data: rawptr) {
    state := cast(^FluidSimState)data
    delete(state.color)
    delete(state.position)
    delete(state.velocity)
    delete(state.acceleration)
    delete(state.density)
    delete(state.particle_index)
    delete(state.spatial_lookup)
    delete(state.start_index)
    free(state)
}

fluidsim_set_init_particle_positions :: proc(system: ^render.CPUParticleSystem, config: ParticleConfig) {
    sim_state := cast(^FluidSimState)system.motion.data

    spacing := config.radius + config.spacing
    grid_size := int(math.ceil(math.sqrt(f32(system.particle_count))))
    offset := render.float3{ f32(-(grid_size - 1)) * 0.5 * spacing, f32(-(grid_size - 1)) * 0.5 * spacing, 0 }

    for i in 0..<system.particle_count {
        col := int(i) % grid_size
        row := int(i) / grid_size
        sim_state.position[i]    = { f32(col) * spacing + offset.x, f32(row) * spacing + offset.y, 0 }
        sim_state.color[i]       = config.default_color
        system.particles[i].size = config.radius
    }
}

fluidsim_update_particles :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    sim_state := cast(^FluidSimState)system.motion.data

    // First, update the particle system with the new config info if it has changed while the program is running
    system.particle_count = sim_state.config.n_particles

    if !sim_state.simulation_started {
        fluidsim_set_init_particle_positions(system, sim_state.config^)
    } else {
        // TODO: Do the physics
    }

    for i in 0..<system.particle_count {
        system.particles[i].position = sim_state.position[i]
        system.particles[i].color    = sim_state.color[i]
    }
}



