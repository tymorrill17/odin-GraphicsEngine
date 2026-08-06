package main

import "render"
import "core:math"
import "core:slice"
import "core:thread"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:math/linalg"
import "core:math/rand"

MAX_PARTICLES :: 5000000

FluidSimParticleConfig :: struct {
    spacing:        f32,
    radius:         f32,
    n_particles:    u32,
    default_color:  render.float4,
}

FluidSimPhysicsConfig :: struct {
    gravity:                  f32,
    boundary_damping:         f32,
    collision_damping:        f32,
    density_smoothing_radius: f32,
    pressure_constant:        f32,
    rest_density:             f32,
    n_substeps:               u32,
    time_step:                f32,
    max_time_step:            f32,
};

FluidSimState :: struct($N: int) {
    system:             ^render.CPUParticleSystem,
    particle_cfg:       ^FluidSimParticleConfig,
    physics_cfg:        ^FluidSimPhysicsConfig,
    bbox:               BoundingBox(N),

    // Particle properties
    density:            []f32,
    acceleration:       [][N]f32,
    velocity:           [][N]f32,
    position:           [][N]f32,
    color:              []render.float4,

    // Pertaining to spatial hashing
    particle_index:     []u32,
    start_index:        []u32,
    spatial_lookup:     []u32,

    // Extra needed quantities
    positions2:         [][N]f32,
    velocities2:        [][N]f32,
    l2:                 [][N]f32,

    particle_count:     u32,
    accumulated_time:   f32,
}

NeighborhoodIterator :: struct($N: int) {
    sim_state:              ^FluidSimState(N),
    position:               [N]f32,
    particle_positions:     [^][N]f32,
    grid_cell:              [N]i32,
    smoothing_radius_sq:    f32,
    offset_idx:             int,
    offset_count:           int,
    particle_idx:           u32,
    grid_key:               u32,
}

BoundingBox :: struct($N: int) {
    min: [N]f32,
    max: [N]f32,
}

BoundingBox2D :: BoundingBox(2)
BoundingBox3D :: BoundingBox(3)

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

fluidsim_state_create :: proc(system: ^render.CPUParticleSystem, particle_cfg: ^FluidSimParticleConfig, physics_cfg: ^FluidSimPhysicsConfig, bounds: BoundingBox($N)) -> render.ParticleMotion {
    state := new(FluidSimState(N))
    state.system             = system
    state.particle_cfg       = particle_cfg
    state.physics_cfg        = physics_cfg
    state.color              = make([]render.float4, system.max_particles)
    state.position           = make([][N]f32, system.max_particles)
    state.velocity           = make([][N]f32, system.max_particles)
    state.acceleration       = make([][N]f32, system.max_particles)
    state.density            = make([]f32, system.max_particles)
    state.particle_index     = make([]u32, system.max_particles)
    state.spatial_lookup     = make([]u32, system.max_particles)
    state.start_index        = make([]u32, system.max_particles)
    state.particle_count     = system.particle_count
    state.bbox               = bounds
    state.accumulated_time   = 0

    state.positions2         = make([][N]f32, system.max_particles)
    state.velocities2        = make([][N]f32, system.max_particles)
    state.l2                 = make([][N]f32, system.max_particles)

    when N == 2 {
        return render.ParticleMotion{ data = state, started = false, update = fluidsim_update_particles_2d, destroy = fluidsim_state_destroy_2d }
    } else when N == 3 {
        return render.ParticleMotion{ data = state, started = false, update = fluidsim_update_particles_3d, destroy = fluidsim_state_destroy_3d }
    } else {
        #panic("FluidSimState only supports N == 2 or N == 3")
    }
}

@(private="file")
fluidsim_state_destroy_2d :: proc(data: rawptr) {
    fluidsim_state_destroy(2, data)
}
@(private="file")
fluidsim_state_destroy_3d :: proc(data: rawptr) {
    fluidsim_state_destroy(3, data)
}

@(private="file")
fluidsim_state_destroy :: proc($N: int, data: rawptr) {
    state := cast(^FluidSimState(N))data
    delete(state.color)
    delete(state.position)
    delete(state.velocity)
    delete(state.acceleration)
    delete(state.density)
    delete(state.particle_index)
    delete(state.spatial_lookup)
    delete(state.start_index)

    delete(state.positions2)
    delete(state.velocities2)
    delete(state.l2)

    free(state)
}

@(private="file")
fluidsim_set_init_particle_positions :: proc(system: ^render.CPUParticleSystem, sim_state: ^FluidSimState($N), particle_cfg: FluidSimParticleConfig) {
    spacing := particle_cfg.radius + particle_cfg.spacing
    grid_size := int(math.ceil(math.sqrt(f32(system.particle_count))))

    offset: [N]f32
    offset[0] = f32(-(grid_size - 1)) * 0.5 * spacing
    offset[1] = f32(-(grid_size - 1)) * 0.5 * spacing

    for i in 0..<system.particle_count {
        col := int(i) % grid_size
        row := int(i) / grid_size

        pos: [N]f32
        pos[0] = f32(col) * spacing + offset[0]
        pos[1] = f32(row) * spacing + offset[1]

        sim_state.position[i]       = pos
        sim_state.acceleration[i]   = 0
        sim_state.velocity[i]       = 0
        sim_state.color[i]          = particle_cfg.default_color
        system.particles[i].size    = particle_cfg.radius
    }
}

@(private="file")
fluidsim_update_particles_2d :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    fluidsim_update_particles(2, system, dt)
}
@(private="file")
fluidsim_update_particles_3d :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    fluidsim_update_particles(3, system, dt)
}

@(private="file")
fluidsim_update_particles :: proc($N: int, system: ^render.CPUParticleSystem, dt: f32) {
    sim_state := cast(^FluidSimState(N))system.motion.data

    // First, update the particle system with the new config info if it has changed while the program is running
    system.particle_count    = sim_state.particle_cfg.n_particles
    sim_state.particle_count = sim_state.particle_cfg.n_particles
    if sim_state.particle_cfg.radius != system.particles[0].size {
        for i in 0..<system.particle_count {
            system.particles[i].size = sim_state.particle_cfg.radius
        }
    }

    assert(sim_state.physics_cfg.n_substeps != 0)

    if !system.motion.started {
        sim_state.accumulated_time = 0
        fluidsim_set_init_particle_positions(system, sim_state, sim_state.particle_cfg^)
    } else {
        sim_state.accumulated_time += math.min(dt, sim_state.physics_cfg.max_time_step)
        for sim_state.accumulated_time >= sim_state.physics_cfg.time_step {
            sub_dt := sim_state.physics_cfg.time_step / f32(sim_state.physics_cfg.n_substeps)
            for _ in 0..<sim_state.physics_cfg.n_substeps {
                // update spatial lookup table
                update_spatial_lookup(sim_state.position, sim_state)

                // calculate particle densities
                calculate_all_densities(sim_state.position, sim_state)

                // get acceleration
                calculate_all_accelerations(sim_state.position, sim_state.velocity, sim_state)

                // find k2 and l2
                for i in 0..<sim_state.particle_count {
                    sim_state.velocities2[i] = sim_state.velocity[i] + sub_dt * sim_state.acceleration[i]
                    sim_state.positions2[i] = sim_state.position[i] + sub_dt * sim_state.velocity[i] // TODO: Should I use velocity or velocities2?
                }
                // update spatial lookup for 2nd particles array (should this happen?)
                update_spatial_lookup(sim_state.positions2, sim_state)
                // calculate particle densities for 2nd particles array
                calculate_all_densities(sim_state.positions2, sim_state)
                // get acceleration (for 2nd particles array
                calculate_all_accelerations_to_array(sim_state.positions2, sim_state.velocities2, sim_state, sim_state.l2)

                // combine both particles array to get the next pos and vel
                half_dt := sub_dt * 0.5
                for i in 0..<sim_state.particle_count {
                    sim_state.position[i] += half_dt * (sim_state.velocity[i] + sim_state.velocities2[i])
                    sim_state.velocity[i] += half_dt * (sim_state.acceleration[i] + sim_state.l2[i])
                }

                // resolve boundary collisions
                resolve_boundary_collisions(sim_state)
            }
            sim_state.accumulated_time -= sim_state.physics_cfg.time_step
        }
    }

    for i in 0..<system.particle_count {
        when N == 2 {
            system.particles[i].position = { sim_state.position[i][0], sim_state.position[i][1], 0 }
        } else when N == 3 {
            system.particles[i].position = sim_state.position[i]
        }
        system.particles[i].color = sim_state.color[i]
    }
}

@(private="file")
get_grid_cell :: proc(position: [$N]f32, cell_size: f32) -> [N]i32 {
    cell: [N]i32
    for d in 0..<N do cell[d] = i32(math.floor(position[d] / cell_size))
    return cell
}

@(private="file")
GRID_HASH_PRIMES := [3]u32{ 73856093, 19349663, 83492791 }

@(private="file")
hash_grid_cell :: proc(grid_cell: [$N]i32, hash_size: u32) -> u32 {
    hash: u32 = 0
    for i in 0..<N do hash += u32(grid_cell[i]) * GRID_HASH_PRIMES[i]
    return hash % hash_size
}

// Discretize space into an infinite grid. Populate the lookup table and sort it based on its hash value.
@(private="file")
update_spatial_lookup :: proc(positions: [][$N]f32, sim_state: ^FluidSimState(N)) {
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
calculate_density :: proc(particle_idx: u32, particle_positions: [][$N]f32, sim_state: ^FluidSimState(N)) -> f32 {
    density: f32 = 0.0
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, _, ok := neighborhood_iterator_next(&iter); ok; dist, _, ok = neighborhood_iterator_next(&iter) {
        dist_sq := linalg.dot(dist, dist)
        when N == 2 {
            density += kernel_smooth_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius)
        } else when N == 3 {
            // TODO: the smoothing kernel still needs to be adapted to 3D
            density += kernel_smooth_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius)
        }
    }
    assert(density != 0)
    return density
}

@(private="file")
calculate_all_densities :: proc(particle_positions: [][$N]f32, sim_state: ^FluidSimState(N)) {
    for i in 0..<sim_state.particle_count {
        sim_state.density[i] = calculate_density(i, particle_positions, sim_state)
    }
}

@(private="file")
calculate_acceleration :: proc(particle_idx: u32, particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N)) -> [N]f32 {
    // Apply interaction force from the hand
    hand_acceleration: [N]f32 = 0

    // Get the pressure force and convert it to acceleration by dividing density
    pressure_acceleration := calculate_pressure_force(particle_idx, particle_positions, sim_state.density, sim_state) / sim_state.density[particle_idx]

    gravity_dir: [N]f32
    gravity_dir.y = -1
    gravity_acceleration := gravity_dir * sim_state.physics_cfg.gravity

    return hand_acceleration + pressure_acceleration + gravity_acceleration
}

@(private="file")
calculate_all_accelerations :: proc(particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N)) {
    for i in 0..<sim_state.particle_count {
        sim_state.acceleration[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}
@(private="file")
calculate_all_accelerations_to_array :: proc(particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N), out_accel: [][N]f32) {
    for i in 0..<sim_state.particle_count {
        out_accel[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}

@(private="file")
get_pressure :: proc(density: f32, physics_cfg: ^FluidSimPhysicsConfig) -> f32 {
    return (density - physics_cfg.rest_density) * physics_cfg.pressure_constant
}

@(private="file")
get_shared_pressure :: proc(density, other_density: f32, physics_cfg: ^FluidSimPhysicsConfig) -> f32 {
    pressure := get_pressure(density, physics_cfg)
    other_pressure := get_pressure(other_density, physics_cfg)
    return (pressure + other_pressure) * 0.5
}

@(private="file")
get_random_dir :: proc($N: int) -> [N]f32 {
    dir: [N]f32
    length_sq: f32
    for {
        for d in 0..<N do dir[d] = f32(rand.norm_float64())
        length_sq = linalg.dot(dir, dir)
        if length_sq > 0 do break
    }
    return dir / math.sqrt(length_sq)
}

@(private="file")
calculate_pressure_force :: proc(particle_idx: u32, particle_positions: [][$N]f32, densities: []f32, sim_state: ^FluidSimState(N)) -> [N]f32 {
    force: [N]f32 = 0
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, index, ok := neighborhood_iterator_next(&iter); ok; dist, index, ok = neighborhood_iterator_next(&iter) {
        if (index == particle_idx) do continue // Particle does not contribute to its own pressure force
        dist_sq := linalg.dot(dist, dist)
        dir := dist_sq == 0 ? get_random_dir(N) : dist / linalg.length(dist) // If particles occupy the same location, select a random force direction

        pressure := get_shared_pressure(densities[particle_idx], densities[index], sim_state.physics_cfg)
        when N == 2 {
            force += pressure * dir * kernel_spikey_derivative_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        } else when N == 3 {
            // TODO: kernel_spikey_derivative_3D
            force += pressure * dir * kernel_spikey_derivative_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        }
    }
    return force
}

@(private="file")
resolve_boundary_collisions :: proc(sim_state: ^FluidSimState($N)) {
    for i in 0..<sim_state.particle_count {
        for dim in 0..<N {
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

@(private="file")
neighborhood_iterator_make :: proc(sim_state: ^FluidSimState($N), position: [N]f32, particle_positions: [^][N]f32) -> NeighborhoodIterator(N) {
    radius := sim_state.physics_cfg.density_smoothing_radius

    // 3 choices for neighboring cells to visit per axis: -1, 0, or 1
    offset_count := 1
    for _ in 0..<N do offset_count *= 3

    return NeighborhoodIterator(N){
        sim_state           = sim_state,
        position            = position,
        particle_positions  = particle_positions,
        grid_cell           = get_grid_cell(position, radius),
        smoothing_radius_sq = radius * radius,
        offset_idx          = -1,
        offset_count        = offset_count,
        particle_idx        = 0,
        grid_key            = 0,
    }
}

@(private="file")
neighborhood_iterator_next :: proc(it: ^NeighborhoodIterator($N)) -> (dist: [N]f32, particle_index: u32, ok: bool) {
    sim_state := it.sim_state

    for {
        // Find the next neighbor grid cell
        if it.offset_idx == -1 || it.particle_idx >= sim_state.particle_count || sim_state.spatial_lookup[it.particle_idx] != it.grid_key {
            it.offset_idx += 1
            if it.offset_idx >= it.offset_count do return {}, 0, false

            // Convert offset_idx to the offset index vector
            offset: [N]i32
            rem := it.offset_idx
            for i in 0..<N {
                offset[i] = i32(rem % 3) - 1
                rem /= 3
            }

            neighbor_cell := it.grid_cell + offset
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

// TODO: Make 3D versions of these kernel functions
kernel_smooth_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    radius_sq := radius * radius
    if dist_sq > radius_sq do return 0
    return 4 / (math.PI * math.pow(radius, 8)) * math.pow(radius_sq - dist_sq, 3)
}

kernel_smooth_derivative_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -24 / (math.PI * math.pow(radius, 8)) * r * math.pow(radius * radius - dist_sq, 2)
}

kernel_spikey_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 10 / (math.PI * math.pow(radius, 5)) * math.pow(radius - r, 3)
}

kernel_spikey_derivative_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -30 / (math.PI * math.pow(radius, 5)) * math.pow(radius - r, 2)
}
