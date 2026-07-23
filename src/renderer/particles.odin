package renderer

import vk "vendor:vulkan"
import "core:math/linalg"

// TODO: These particles are too general, make some simpler ones for faster simulation

// Describes an instance of a particle for the renderer
ParticleInstance :: struct {
    position:   [3]f32,
    size:       f32,
    color:      [4]f32,
}

// Simulation state for each particle
// This is just an example for now
Particle :: struct {
    position:   [3]f32,
    velocity:   [3]f32,
    color:      [4]f32,
    size:       f32,
    life:       f32,
    max_life:   f32,
}

ParticleSystem :: struct {
    particles:              []Particle,
    particle_count:         u32,
    max_particles:          u32,
    instance_buffers:       []Buffer, // one instance buffer per frame_in_flight
    instance_buffer_addrs:  []vk.DeviceAddress,
    mesh:                   ^MeshAsset, // geometry to use for the particles
    material:               ^MaterialInstance, // material pipeline to use for the rendered particles
    transform:              matrix[4,4]f32,
}

particle_system_get_render_object :: proc(system: ^ParticleSystem, renderer: ^Renderer) -> RenderObject {
    return RenderObject{
        index_count             = system.mesh.surfaces[0].count,
        first_index             = system.mesh.surfaces[0].start_index,
        index_buffer            = system.mesh.mesh_buffers.index_buffer.handle,
        material                = system.material,
        transform               = system.transform,
        vertex_buffer_addr      = system.mesh.mesh_buffers.vertex_buffer_addr,
        instance_buffer_addr    = system.instance_buffer_addrs[renderer.frame_index],
        instance_count          = u32(len(system.particles)),
    }
}

particle_system_create :: proc(renderer: ^Renderer, max_particles: u32, origin: [3]f32,
    particle_mesh: ^MeshAsset, material: ^MaterialInstance) -> ParticleSystem {

    system := ParticleSystem{
        max_particles   = max_particles,
        transform       = linalg.matrix4_translate_f32(origin),
        material        = material,
        mesh            = particle_mesh,
        particle_count  = max_particles, // for now
    }

    system.particles             = make([]Particle, max_particles)
    system.instance_buffers      = make([]Buffer, renderer.frames_in_flight)
    system.instance_buffer_addrs = make([]vk.DeviceAddress, renderer.frames_in_flight)

    for i in 0..<renderer.frames_in_flight {
        system.instance_buffers[i] = buffer_create(renderer, size_of(ParticleInstance), u64(max_particles), { .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS }, .CPU_TO_GPU)
        addr_info := vk.BufferDeviceAddressInfo{
            sType  = vk.StructureType.BUFFER_DEVICE_ADDRESS_INFO,
            buffer = system.instance_buffers[i].handle,
        }
        system.instance_buffer_addrs[i] = vk.GetBufferDeviceAddress(renderer.logical_device, &addr_info)
        buffer_map(renderer, &system.instance_buffers[i])
    }

    return system
}

particle_system_destroy :: proc(system: ^ParticleSystem, renderer: ^Renderer) {
    for i in 0..<len(system.instance_buffers) {
        buffer_destroy(renderer, &system.instance_buffers[i])
    }
    delete(system.instance_buffers)
    delete(system.instance_buffer_addrs)
    delete(system.particles)
}
