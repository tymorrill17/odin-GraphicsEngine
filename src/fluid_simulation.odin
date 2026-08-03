package main

import "render"
import "core:math"
import "core:slice"
import "core:math/linalg"
import "core:math/rand"

FluidSimParticleConfig :: struct {
    spacing:        f32,
    radius:         f32,
    n_particles:    u32,
    default_color:  render.float4,
}

MAX_PARTICLES :: 5000000

FluidSimState :: struct {
    system:             ^render.CPUParticleSystem,
    particle_cfg:       ^FluidSimParticleConfig,
    physics_cfg:        ^FluidSimPhysicsConfig,
    bbox:               BoundingBox3D,

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

    particle_count:     u32,
    simulation_started: bool,
}

FluidSimPhysicsConfig :: struct {
    gravity:                  f32,
	boundary_damping:         f32,
	collision_damping:        f32,
	density_smoothing_radius: f32,
	pressure_constant:        f32,
	rest_density:             f32,
	n_substeps:               u32,
};

BoundingBox3D :: struct {
    min: render.float3,
    max: render.float3,
}

@(private="file")
GRID_CELL_OFFSETS: []render.int3 : {
    { -1, -1, -1 }, { -1, -1, 0 }, { -1, -1, 1 },
    { -1,  0, -1 }, { -1,  0, 0 }, { -1,  0, 1 },
    { -1,  1, -1 }, { -1,  1, 0 }, { -1,  1, 1 },

     { 0, -1, -1 },  { 0, -1, 0 },  { 0, -1, 1 },
     { 0,  0, -1 },  { 0,  0, 0 },  { 0,  0, 1 },
     { 0,  1, -1 },  { 0,  1, 0 },  { 0,  1, 1 },

     { 1, -1, -1 },  { 1, -1, 0 },  { 1, -1, 1 },
     { 1,  0, -1 },  { 1,  0, 0 },  { 1,  0, 1 },
     { 1,  1, -1 },  { 1,  1, 0 },  { 1,  1, 1 },
}

NeighborhoodIterator :: struct {
    sim_state:              ^FluidSimState,
    position:               render.float3,
    particle_positions:     [^]render.float3,
    grid_cell:              render.int3,
    smoothing_radius_sq:    f32,
    offset_idx:             int,
    particle_idx:           u32,
    grid_key:               u32,
}

neighborhood_iterator_make :: proc(sim_state: ^FluidSimState, position: render.float3, particle_positions: [^]render.float3) -> NeighborhoodIterator {
    radius := sim_state.physics_cfg.density_smoothing_radius
    return NeighborhoodIterator{
        sim_state           = sim_state,
        position            = position,
        particle_positions  = particle_positions,
        grid_cell           = get_grid_cell(position, radius),
        smoothing_radius_sq = radius * radius,
        offset_idx          = -1,
        particle_idx        = 0,
        grid_key            = 0,
    }
}

neighborhood_iterator_next :: proc(it: ^NeighborhoodIterator) -> (dist: render.float3, particle_index: u32, ok: bool) {
    sim_state := it.sim_state
    grid_offsets := GRID_CELL_OFFSETS

    for {
        // Find the next neighbor grid cell
        if it.offset_idx == -1 || it.particle_idx >= sim_state.particle_count || sim_state.spatial_lookup[it.particle_idx] != it.grid_key {
            it.offset_idx += 1
            if it.offset_idx >= len(grid_offsets) do return {}, 0, false

            neighbor_cell := it.grid_cell + grid_offsets[it.offset_idx]
            it.grid_key     = hash_grid_cell(neighbor_cell, sim_state.particle_count) // Store the grid key for the offset cell
            it.particle_idx = sim_state.start_index[it.grid_key] // Find the first particle in the offset cell
            continue
        }

        // Set the return value for the particle index of the current particle being iterated over
        particle_index = sim_state.particle_index[it.particle_idx]
        it.particle_idx += 1

        dist = it.particle_positions[particle_index] - it.position
        square_dst := linalg.dot(dist, dist) // To avoid sqrt
        if square_dst <= it.smoothing_radius_sq {
            return dist, particle_index, true
        }
    }
}

// NOTE: Not using for now. Came up with a better way for Odin
// @(private="file")
// loop_through_neighborhood :: proc(location: render.float3, particle_positions: []render.float3, sim_state: ^FluidSimState, callback: proc(render.float3, u32) -> f32) -> f32 {
//     grid_cell := get_grid_cell(location, sim_state.physics_cfg.density_smoothing_radius)
//     smoothing_radius_sq := sim_state.physics_cfg.density_smoothing_radius * sim_state.physics_cfg.density_smoothing_radius
//
//     for offset in GRID_CELL_OFFSETS {
//         grid_key := hash_grid_cell(grid_cell + offset, sim_state.particle_count)
//         cell_start_idx := sim_state.start_index[grid_key]
//
//         for i in cell_start_idx..<sim_state.particle_count {
//             if sim_state.spatial_lookup[i] != grid_key do break
//
//             particle_idx := sim_state.particle_index[i]
//             dist := particle_positions[particle_idx] - location
//             dist_sq := linalg.dot(dist, dist)
//             if dist_sq <= smoothing_radius_sq do return callback(dist, particle_idx)
//         }
//     }
//     return 0
// }

// Create pipeline and descriptor sets for the fluid render object
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

fluidsim_state_create :: proc(system: ^render.CPUParticleSystem, particle_cfg: ^FluidSimParticleConfig, physics_cfg: ^FluidSimPhysicsConfig, bounds: BoundingBox3D) -> render.ParticleMotion {
    state := new(FluidSimState)
    state.system             = system
    state.particle_cfg       = particle_cfg
    state.physics_cfg        = physics_cfg
    state.color              = make([]render.float4, system.max_particles)
    state.position           = make([]render.float3, system.max_particles)
    state.velocity           = make([]render.float3, system.max_particles)
    state.acceleration       = make([]render.float3, system.max_particles)
    state.density            = make([]f32, system.max_particles)
    state.particle_index     = make([]u32, system.max_particles)
    state.spatial_lookup     = make([]u32, system.max_particles)
    state.start_index        = make([]u32, system.max_particles)
    state.simulation_started = false
    state.particle_count     = system.particle_count
    state.bbox               = bounds

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

fluidsim_set_init_particle_positions :: proc(system: ^render.CPUParticleSystem, particle_cfg: FluidSimParticleConfig) {
    sim_state := cast(^FluidSimState)system.motion.data

    spacing := particle_cfg.radius + particle_cfg.spacing
    grid_size := int(math.ceil(math.sqrt(f32(system.particle_count))))
    offset := render.float3{ f32(-(grid_size - 1)) * 0.5 * spacing, f32(-(grid_size - 1)) * 0.5 * spacing, 0 }

    for i in 0..<system.particle_count {
        col := int(i) % grid_size
        row := int(i) / grid_size
        sim_state.position[i]    = { f32(col) * spacing + offset.x, f32(row) * spacing + offset.y, 0 }
        sim_state.color[i]       = particle_cfg.default_color
        system.particles[i].size = particle_cfg.radius
    }
}

fluidsim_start :: proc(system: ^render.CPUParticleSystem) {
    sim_state := cast(^FluidSimState)system.motion.data
    sim_state.simulation_started = true;
}

fluidsim_reset :: proc(system: ^render.CPUParticleSystem) {
    sim_state := cast(^FluidSimState)system.motion.data
    sim_state.simulation_started = false
}

fluidsim_update_particles :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    sim_state := cast(^FluidSimState)system.motion.data

    // First, update the particle system with the new config info if it has changed while the program is running
    system.particle_count    = sim_state.particle_cfg.n_particles
    sim_state.particle_count = sim_state.particle_cfg.n_particles
    if sim_state.particle_cfg.radius != system.particles[0].size {
        for i in 0..<system.particle_count {
            system.particles[i].size = sim_state.particle_cfg.radius
        }
    }

    assert(sim_state.physics_cfg.n_substeps != 0)
    sub_dt := dt / f32(sim_state.physics_cfg.n_substeps)

    if !sim_state.simulation_started {
        fluidsim_set_init_particle_positions(system, sim_state.particle_cfg^)
    } else {
        // TODO: Do the physics

        // We should already have timing data, but may have to divide into substeps here

        // update spatial lookup table
        update_spatial_lookup(sim_state.position, sim_state)

        // calculate particle densities
        calculate_all_densities(sim_state.position, sim_state)

        // get acceleration
        calculate_all_accelerations(sim_state.position, sim_state.velocity, sim_state)

        // find k2 and l2
        positions2 := make([]render.float3, sim_state.particle_count)
        velocities2 := make([]render.float3, sim_state.particle_count)
        l2 := make([]render.float3, sim_state.particle_count)
        defer delete(positions2)
        defer delete(velocities2)
        defer delete(l2)
        for i in 0..<sim_state.particle_count {
            velocities2[i] = sim_state.velocity[i] + sub_dt * sim_state.acceleration[i]
            positions2[i] = sim_state.position[i] + sub_dt * sim_state.velocity[i] // TODO: Should I use velocity or velocities2?
        }
        // update spatial lookup for 2nd particles array (should this happen?)
        update_spatial_lookup(positions2, sim_state)
        // calculate particle densities for 2nd particles array
        calculate_all_densities(positions2, sim_state)
        // get acceleration (for 2nd particles array
        calculate_all_accelerations_to_array(positions2, velocities2, sim_state, &l2)

        // combine both particles array to get the next pos and vel
        half_dt := dt * 0.5
        for i in 0..<sim_state.particle_count {
            sim_state.position[i] += half_dt * (sim_state.velocity[i] + velocities2[i])
            sim_state.velocity[i] += half_dt * (sim_state.acceleration[i] + l2[i])
        }

        // resolve boundary collisions
        resolve_boundary_collisions(sim_state)
    }

    for i in 0..<system.particle_count {
        system.particles[i].position = sim_state.position[i]
        system.particles[i].color    = sim_state.color[i]
    }
}

@(private="file")
get_grid_cell :: proc(position: render.float3, cell_size: f32) -> render.int3 {
    cell: render.int3
    cell.x = i32(math.floor(position.x / cell_size))
    cell.y = i32(math.floor(position.y / cell_size))
    cell.z = i32(math.floor(position.z / cell_size))
    return cell
}

@(private="file")
hash_grid_cell :: proc(grid_cell: render.int3, hash_size: u32) -> u32 {
    px: u32 = 73856093;
    py: u32 = 19349663;
    pz: u32 = 83492791;
    return (u32(grid_cell.x) * px + u32(grid_cell.y) * py + u32(grid_cell.z) * pz) % hash_size
}

// Discretize space into an infinite grid. Populate the lookup table and sort it based on its hash value.
@(private="file")
update_spatial_lookup :: proc(positions: []render.float3, sim_state: ^FluidSimState) {
    for i in 0..<sim_state.particle_count {
        grid_cell_index := get_grid_cell(positions[i], sim_state.physics_cfg.density_smoothing_radius)
        grid_cell_hash  := hash_grid_cell(grid_cell_index, sim_state.particle_count)

        // Each particle has a spatial lookup value in the form of a hash of the grid cell index.
        // The particles will be sorted based on their grid_cell_hash so that particles in the same
        // cell are adjacent in the array. The start_index array holds the first index in a contiguous
        // sequence of particles in one cell.
        sim_state.particle_index[i] = u32(i)
        sim_state.spatial_lookup[i] = grid_cell_hash
        sim_state.start_index[i]    = max(u32) // maximum value of a u32
    }

    // Sorts sim_state.spatial_lookup in place, and returns the permutation in indices
    indices := slice.sort_with_indices(sim_state.spatial_lookup[:sim_state.particle_count])
    defer delete(indices)
    slice.sort_by_indices_overwrite(sim_state.particle_index[:sim_state.particle_count], indices) // Use the permutation to sort the particle_index array

    // This loop updates the start indices
    for i in 0..<sim_state.particle_count {
        grid_key := sim_state.spatial_lookup[i]
        prev_grid_key := i == 0 ? max(u32) : sim_state.spatial_lookup[i - 1]
        if grid_key != prev_grid_key do sim_state.start_index[grid_key] = i // If hashes differ, we are in a new grid entry, so a new start_index
    }
}

@(private="file")
calculate_density :: proc(particle_idx: u32, particle_positions: []render.float3, sim_state: ^FluidSimState) -> f32 {
    density: f32 = 0.0
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, _, ok := neighborhood_iterator_next(&iter); ok; dist, _, ok = neighborhood_iterator_next(&iter) {
        dist_sq := linalg.dot(dist, dist)
        density += kernel_smooth_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius)
    }
    assert(density != 0)
    return density
}

@(private="file")
calculate_all_densities :: proc(particle_positions: []render.float3, sim_state: ^FluidSimState) {
    for i in 0..<sim_state.particle_count {
        sim_state.density[i] = calculate_density(i, particle_positions, sim_state)
    }
}

@(private="file")
calculate_acceleration :: proc(particle_idx: u32, particle_positions, particle_velocities: []render.float3, sim_state: ^FluidSimState) -> render.float3 {
    // Apply interaction force from the hand
    hand_acceleration:      render.float3 = 0

    // Get the pressure force and convert it to acceleration by dividing density
    pressure_acceleration := calculate_pressure_force(particle_idx, particle_positions, sim_state.density, sim_state) / sim_state.density[particle_idx]
    gravity_acceleration := render.float3{ 0, -1, 0 } * sim_state.physics_cfg.gravity
    return hand_acceleration + pressure_acceleration + gravity_acceleration
}

@(private="file")
calculate_all_accelerations :: proc(particle_positions, particle_velocities: []render.float3, sim_state: ^FluidSimState) {
    for i in 0..<sim_state.particle_count {
        sim_state.acceleration[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}
@(private="file")
calculate_all_accelerations_to_array :: proc(particle_positions, particle_velocities: []render.float3, sim_state: ^FluidSimState, out_accel: ^[]render.float3) {
    for i in 0..<u32(len(out_accel)) {
        out_accel[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}

@(private="file")
get_pressure :: proc(density: f32, sim_state: ^FluidSimState) -> f32 {
    return (density - sim_state.physics_cfg.rest_density) * sim_state.physics_cfg.pressure_constant
}

@(private="file")
get_shared_pressure :: proc(density, other_density: f32, sim_state: ^FluidSimState) -> f32 {
    pressure := get_pressure(density, sim_state)
    other_pressure := get_pressure(other_density, sim_state)
    return (pressure + other_pressure) * 0.5
}

@(private="file")
get_random_dir :: proc() -> render.float3 {
    dir: render.float3
    length_sq: f32
    for {
        dir = {
            f32(rand.norm_float64()),
            f32(rand.norm_float64()),
            f32(rand.norm_float64()),
        }
        length_sq = linalg.dot(dir, dir)
        if length_sq > 0 do break
    }
    return dir / math.sqrt(length_sq)
}

@(private="file")
calculate_pressure_force :: proc(particle_idx: u32, particle_positions: []render.float3, densities: []f32, sim_state: ^FluidSimState) -> render.float3 {
    force := render.float3{ 0, 0, 0 }
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, index, ok := neighborhood_iterator_next(&iter); ok; dist, index, ok = neighborhood_iterator_next(&iter) {
        if (index == particle_idx) do continue // Particle does not contribute to its own pressure force
        dist_sq := linalg.dot(dist, dist)
        dir := dist_sq == 0 ? get_random_dir() : dist / linalg.length(dist) // If particles occupy the same location, select a random force direction

        force += get_shared_pressure(densities[particle_idx], densities[index], sim_state) * dir * kernel_spikey_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
    }
    return force
}

@(private="file")
resolve_boundary_collisions :: proc(sim_state: ^FluidSimState) {
    for i in 0..<sim_state.particle_count {
        for dim in 0..<3 {
            if sim_state.position[i][dim] > (sim_state.bbox.max[dim] - sim_state.particle_cfg.radius) {
                sim_state.position[i][dim] = sim_state.bbox.max[dim] - sim_state.particle_cfg.radius
                sim_state.velocity[i][dim] = -sim_state.velocity[i][dim] * sim_state.physics_cfg.boundary_damping
            } else if sim_state.position[i][dim] < (sim_state.bbox.min[dim] + sim_state.particle_cfg.radius) {
                sim_state.position[i][dim] = sim_state.bbox.min[dim] + sim_state.particle_cfg.radius
                sim_state.velocity[i][dim] = -sim_state.velocity[i][dim] * sim_state.physics_cfg.boundary_damping
            }
        }
    }
}

// TODO: This is currently 2D. Need to make this 3D
kernel_smooth_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    radius_sq := radius * radius
    if dist_sq > radius_sq do return 0
    return 4 / (math.PI * math.pow(radius, 8)) * math.pow(radius_sq - dist_sq, 2)
}

kernel_spikey_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 10 / (math.PI * math.pow(radius, 5)) * math.pow(radius - r, 3)
}
