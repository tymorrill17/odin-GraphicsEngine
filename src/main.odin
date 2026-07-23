package main

import "thirdparty:imgui"
import vk "vendor:vulkan"
import "renderer"
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

main :: proc() {

    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger

    renderer_config := renderer.RendererConfig{
        app_name                        = "Renderer",
        extent                          = {APPLICATION_WIDTH, APPLICATION_HEIGHT},
        use_discrete_GPU                = true,
        validation_layers               = requested_validation_layers,
        device_extensions               = requested_device_extensions,
        initial_descriptor_set_count    = 10,
    }

    r: renderer.Renderer
    renderer.renderer_initialize(&r, renderer_config)
    defer renderer.renderer_shutdown(&r)

    global_uniform_buffer := renderer.buffer_create(&r, size_of(CameraData), 1, { .UNIFORM_BUFFER }, .CPU_TO_GPU)
    defer renderer.buffer_destroy(&r, &global_uniform_buffer)
    camera_data := CameraData{
        viewproj = (1), // initialize to identity matrix
        model    = (1),
    }

    layout_builder: renderer.DescriptorLayoutBuilder
    renderer.descriptor_layout_builder_create()
    defer renderer.descriptor_layout_builder_destroy(&layout_builder)
    defer renderer.descriptor_layout_builder_destroy_built_layouts(&layout_builder, &r)

    renderer.descriptor_layout_builder_add_binding(&layout_builder, 0, .UNIFORM_BUFFER, 1, { .VERTEX })
    global_scene_layout := renderer.descriptor_layout_builder_build(&layout_builder, &r)

    append(&r.scene_descriptors, renderer.descriptor_set_create(&r, { global_scene_layout }))
    descriptor_writer := renderer.descriptor_writer_create()
    defer renderer.descriptor_writer_destroy(&descriptor_writer)

    particle_mesh := renderer.mesh_create_rectangle(&r, 1, 1)
    // TODO: Create Material
    // TODO: Write vertex and fragment shader for particle system rendering
    fluid_material: ^renderer.MaterialInstance // = get_fluid_material()
    n_particles: u32 = 1000

    fluid_particle_system := renderer.particle_system_create(&r, n_particles, (0), particle_mesh, fluid_material)
    defer renderer.particle_system_destroy(&fluid_particle_system, &r)
    append(&r.renderables, renderer.particle_system_get_render_object(&fluid_particle_system, &r))

    camera_config := CameraParams{
        position    = (0),
        center      = (0),
        near_plane  = 0.1,
        far_plane   = 10000,
        scale       = 5,
    };

    for !renderer.window_should_close(&r) {
        renderer.start_frame(&r)

		imgui.Begin("CameraParams");
        imgui.DragFloat3("Position", &camera_config.position, 0.1);
        imgui.DragFloat3("Center", &camera_config.center, 0.1);
        imgui.DragFloat("Far Plane", &camera_config.far_plane, 1);
        imgui.DragFloat("Near Plane", &camera_config.near_plane, 0.001);
        imgui.DragFloat("Orthographic Scale", &camera_config.scale, 0.1);
		imgui.End();

        // TODO: Fill model and viewproj matrices

        // Write to uniform buffer
        renderer.descriptor_writer_add_buffers(&descriptor_writer, r.scene_descriptors[0], 0, { global_uniform_buffer }, .UNIFORM_BUFFER)
        renderer.descriptor_writer_update_sets(&descriptor_writer, &r)

        renderer.draw(&r)
    }
}
