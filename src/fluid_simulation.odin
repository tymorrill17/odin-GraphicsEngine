package main

import "render"
import "core:math"

ParticleConfig :: struct {
    spacing:        f32,
    radius:         f32,
    n_particles:    u32,
    default_color:  [4]f32,
}

MAX_PARTICLES :: 5000000

fluidsim_get_material :: proc(renderer: ^render.Renderer) -> render.MaterialInstance{

    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "particle.slang.spv")
    defer render.shader_module_destroy(renderer, shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .VERTEX }, "vertex_main")
    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .FRAGMENT }, "fragment_main")
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

fluidsim_set_init_particle_positions :: proc(renderer: ^render.Renderer, system: ^render.CPUParticleSystem, config: ^ParticleConfig) {

    spacing := config.radius + config.spacing
    grid_size := int(math.ceil(math.sqrt(f32(system.particle_count))))
    offset := [3]f32{ f32(-(grid_size - 1)) * 0.5 * spacing, f32(-(grid_size - 1)) * 0.5 * spacing, 0 }

    for i in 0..<system.particle_count {
        col := int(i) % grid_size
        row := int(i) / grid_size
        system.particles[i].position = { f32(col) * spacing + offset.x, f32(row) * spacing + offset.y, 0 }
        system.particles[i].color = config.default_color
        system.particles[i].velocity = 0
    }
}

fluidsim_update_particles :: proc(system: ^render.CPUParticleSystem, renderer: ^render.Renderer, config: ^ParticleConfig, simulation_started: bool) {

    // First, update the particle system with the new config info if it has changed while the program is running
    system.particle_count = config.n_particles

    if !simulation_started {
        fluidsim_set_init_particle_positions(renderer, system, config)
    } else {

    }

    instanced_particles := make([]render.ParticleInstance, system.max_particles)
    defer delete(instanced_particles)
    // TODO: this is essentially doing a second copy for no reason. I should streamline getting relevant info to the shader.
    //      1) Can I write directly into mapped memory?
    //      2) Can I structure relevant particle data to just do the below buffer write?
    for i in 0..<system.particle_count {
        instanced_particles[i] = {position = system.particles[i].position, size = config.radius, color = system.particles[i].color}
    }
    render.buffer_write_data(renderer, &system.particle_buffers[renderer.frame_index], raw_data(instanced_particles))
}



