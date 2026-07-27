package main

import "thirdparty:imgui"
import vk "vendor:vulkan"
import "render"
import "core:log"

APPLICATION_WIDTH  :: 1920
APPLICATION_HEIGHT :: 1080

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type"
}

CameraConfig :: struct{
    position:       [3]f32, // position of camera
    center:         [3]f32, // Where camera is looking
    near_plane:     f32,
    far_plane:      f32,
    scale:          f32,
};

CameraData :: struct {
    viewproj:   matrix[4, 4]f32,
    view:       matrix[4, 4]f32,
    proj:       matrix[4, 4]f32,
};


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

    // Create an instance of the global uniform buffer for each frame in flight
    global_uniform_buffer := render.buffer_create(&r, size_of(CameraData), u64(r.frames_in_flight), { .UNIFORM_BUFFER }, .CPU_TO_GPU)
    defer render.buffer_destroy(&r, &global_uniform_buffer)
    render.buffer_map(&r, &global_uniform_buffer)
    camera_data := CameraData{
        viewproj = (1), // initialize to identity matrix
        view     = (1),
        proj     = (1),
    }

    layout_builder := render.descriptor_layout_builder_create()
    defer render.descriptor_layout_builder_destroy(&layout_builder)
    defer render.descriptor_layout_builder_destroy_built_layouts(&layout_builder, &r)
    descriptor_writer := render.descriptor_writer_create()
    defer render.descriptor_writer_destroy(&descriptor_writer)

    // Build the descriptor layout for the global scene descriptors (like camera data, etc)
    render.descriptor_layout_builder_add_binding(&layout_builder, 0, .UNIFORM_BUFFER_DYNAMIC, 1, { .VERTEX })
    global_scene_layout := render.descriptor_layout_builder_build(&layout_builder, &r)
    append(&r.scene_descriptor_layouts, global_scene_layout)
    camera_descriptor := render.descriptor_set_create(&r, { global_scene_layout })
    append(&r.scene_descriptors, &camera_descriptor)

    // Point the global descriptors to their buffers in the Renderer class
    render.descriptor_writer_add_buffers(&descriptor_writer, r.scene_descriptors[0], 0, { global_uniform_buffer }, .UNIFORM_BUFFER_DYNAMIC)
    render.descriptor_writer_update_sets(&descriptor_writer, &r)

    particle_mesh := render.mesh_create_rectangle(&r, 1, 1)
    defer render.mesh_destroy(&r, particle_mesh)
    fluid_material := fluidsim_get_material(&r)
    defer render.pipeline_destroy(&r, &fluid_material.pipeline)

    fluidsim_particle_system := render.particle_system_create(&r, MAX_PARTICLES, (0), particle_mesh, &fluid_material)
    defer render.particle_system_destroy(&fluidsim_particle_system, &r)
    append(&r.renderables, render.particle_system_get_render_object(&fluidsim_particle_system, &r))

    particle_config := ParticleConfig{
        spacing     = 0.01,
        radius      = 0.1,
        n_particles = 10000,
        default_color = [4]f32{ 1, 1, 1, 1 },
    }

    camera_config := CameraConfig{
        center      = {0, 0, 0},
        position    = {0, 0, 1},
        near_plane  = 0.1,
        far_plane   = 10000,
        scale       = 5,
    };

    for !render.window_should_close(&r) {
        render.start_frame(&r)

		imgui.Begin("Camera Config");
        imgui.DragFloat3("Position", &camera_config.position, 0.1);
        imgui.DragFloat3("Center", &camera_config.center, 0.1);
        imgui.DragFloat("Far Plane", &camera_config.far_plane, 1);
        imgui.DragFloat("Near Plane", &camera_config.near_plane, 0.001);
        imgui.DragFloat("Orthographic Scale", &camera_config.scale, 0.1);
		imgui.End();

		imgui.Begin("Particle Config");
        imgui.DragFloat("Spacing", &particle_config.spacing, 0.01);
        imgui.DragFloat("Radius", &particle_config.radius, .01);
        imgui.DragScalar("Number of Particles", .U32, rawptr(&particle_config.n_particles), .01);
        imgui.ColorPicker4("Default Color", &particle_config.default_color)
		imgui.End();

        aspect_ratio := r.window.aspect_ratio
        up := [3]f32{ 0, 1, 0 }
        camera_data.proj = render.projection_set_orthographic(-aspect_ratio * 0.5 * camera_config.scale, aspect_ratio * 0.5 * camera_config.scale,
            -0.5 * camera_config.scale, 0.5 * camera_config.scale,
            camera_config.near_plane, camera_config.far_plane)
        camera_data.view = render.view_set_direction(camera_config.position, { 0, 0, -1 }, up)
        camera_data.viewproj = camera_data.proj * camera_data.view
        render.buffer_write_data_at_index(&r, &global_uniform_buffer, rawptr(&camera_data), r.frame_index) // Update at the right index for this frame

        // Update fluidsim particles
        fluidsim_update_particles(&fluidsim_particle_system, &r, &particle_config, false)

        render.draw(&r)
    }

    render.wait_idle(&r)
}
