package main

import "thirdparty:imgui"
import vk "vendor:vulkan"
import "render"
import "core:log"

APPLICATION_WIDTH  :: 1280
APPLICATION_HEIGHT :: 720

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type"
}

CameraParams :: struct{
    position:       [3]f32,
    center:         [3]f32,
    near_plane:     f32,
    far_plane:      f32,
    scale:          f32,
};

CameraData :: struct {
    viewproj:   matrix[4, 4]f32,
    model:      matrix[4, 4]f32,
};


get_fluid_material :: proc(renderer: ^render.Renderer) -> render.MaterialInstance{

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
    render.pipeline_cfg_add_descriptor(&pipeline_cfg, renderer.scene_descriptor_layouts[0])

    material: render.MaterialInstance
    material.pass_type = .transparent
    // WARNING: if I have multiple scene descriptors, this will need to change
    material.descriptor = renderer.scene_descriptors[0]
    material.pipeline = render.pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    return material
}


main :: proc() {

    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger

    renderer_config := render.RendererConfig{
        app_name                        = "Renderer",
        extent                          = {APPLICATION_WIDTH, APPLICATION_HEIGHT},
        use_discrete_GPU                = true,
        validation_layers               = requested_validation_layers,
        device_extensions               = requested_device_extensions,
        initial_descriptor_set_count    = 10,
    }

    r: render.Renderer
    render.renderer_initialize(&r, renderer_config)
    defer render.renderer_shutdown(&r)

    global_uniform_buffer := render.buffer_create(&r, size_of(CameraData), 1, { .UNIFORM_BUFFER }, .CPU_TO_GPU)
    defer render.buffer_destroy(&r, &global_uniform_buffer)
    camera_data := CameraData{
        viewproj = (1), // initialize to identity matrix
        model    = (1),
    }

    layout_builder: render.DescriptorLayoutBuilder
    render.descriptor_layout_builder_create()
    defer render.descriptor_layout_builder_destroy(&layout_builder)
    defer render.descriptor_layout_builder_destroy_built_layouts(&layout_builder, &r)

    render.descriptor_layout_builder_add_binding(&layout_builder, 0, .UNIFORM_BUFFER, 1, { .VERTEX })
    global_scene_layout := render.descriptor_layout_builder_build(&layout_builder, &r)

    append(&r.scene_descriptor_layouts, global_scene_layout)
    append(&r.scene_descriptors, render.descriptor_set_create(&r, { global_scene_layout }))
    descriptor_writer := render.descriptor_writer_create()
    defer render.descriptor_writer_destroy(&descriptor_writer)

    particle_mesh := render.mesh_create_rectangle(&r, 1, 1)
    // TODO: Write vertex and fragment shader for particle system rendering
    fluid_material := get_fluid_material(&r)
    n_particles: u32 = 1000

    fluid_particle_system := render.particle_system_create(&r, n_particles, (0), particle_mesh, &fluid_material)
    defer render.particle_system_destroy(&fluid_particle_system, &r)
    append(&r.renderables, render.particle_system_get_render_object(&fluid_particle_system, &r))

    camera_config := CameraParams{
        position    = (0),
        center      = (0),
        near_plane  = 0.1,
        far_plane   = 10000,
        scale       = 5,
    };

    for !render.window_should_close(&r) {
        render.start_frame(&r)

		imgui.Begin("CameraParams");
        imgui.DragFloat3("Position", &camera_config.position, 0.1);
        imgui.DragFloat3("Center", &camera_config.center, 0.1);
        imgui.DragFloat("Far Plane", &camera_config.far_plane, 1);
        imgui.DragFloat("Near Plane", &camera_config.near_plane, 0.001);
        imgui.DragFloat("Orthographic Scale", &camera_config.scale, 0.1);
		imgui.End();

        // TODO: Fill model and viewproj matrices

        // Write to uniform buffer
        render.descriptor_writer_add_buffers(&descriptor_writer, r.scene_descriptors[0], 0, { global_uniform_buffer }, .UNIFORM_BUFFER)
        render.descriptor_writer_update_sets(&descriptor_writer, &r)

        render.draw(&r)
    }
}
