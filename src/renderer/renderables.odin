package renderer

import vk "vendor:vulkan"

MaterialPass :: enum {
    opaque,
    transparent,
}

MaterialInstance :: struct {
    pipeline:   ^Pipeline,
    descriptor: vk.DescriptorSet,
    pass_type:  MaterialPass
}

RenderObject :: struct {
    index_count:            u32,
    first_index:            u32,
    index_buffer:           vk.Buffer, // Don't need the full Buffer object, vk handle suffices
    material:               ^MaterialInstance,
    transform:              matrix[4,4]f32,
    vertex_buffer_addr:     vk.DeviceAddress,
    instance_buffer_addr:   vk.DeviceAddress,
    instance_count:         u32,
}

MeshBuffers :: struct {
    vertex_buffer:      Buffer,
    index_buffer:       Buffer,
    vertex_buffer_addr: vk.DeviceAddress
}

GeometricSurface :: struct {
    start_index:    u32,
    count:          u32,
}

MeshAsset :: struct {
    surfaces:       []GeometricSurface,
    mesh_buffers:   MeshBuffers,
}

MeshVertex :: struct {
    position:   [3]f32,
    uv_x:       f32,
    normal:     [3]f32,
    uv_y:       f32,
    color:      [4]f32,
};

// Send vertex and index data to the GPU by creating buffers and writing to them. Returns the created buffers.
mesh_upload_to_GPU :: proc(renderer: ^Renderer, vertices: []MeshVertex, indices: []u32) -> MeshBuffers {
    vertex_buffer_size := u64(len(vertices) * size_of(MeshVertex))
    index_buffer_size := u64(len(indices) * size_of(u32))

    mesh: MeshBuffers
    mesh.vertex_buffer = buffer_create(renderer, vertex_buffer_size, 1, { .VERTEX_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS }, .GPU_ONLY)
    addr_info := vk.BufferDeviceAddressInfo{
        sType = vk.StructureType.BUFFER_DEVICE_ADDRESS_INFO,
        buffer = mesh.vertex_buffer.handle
    }
    mesh.vertex_buffer_addr = vk.GetBufferDeviceAddress(renderer.logical_device, &addr_info)
    mesh.index_buffer = buffer_create(renderer, index_buffer_size, 1, { .INDEX_BUFFER, .TRANSFER_DST }, .GPU_ONLY)

    staging_buffer := buffer_create(renderer, vertex_buffer_size + index_buffer_size, 1, { .TRANSFER_SRC }, .CPU_ONLY)
    defer buffer_destroy(renderer, &staging_buffer)
    buffer_write_data(renderer, &staging_buffer, raw_data(vertices), vertex_buffer_size)
    buffer_write_data(renderer, &staging_buffer, raw_data(indices), index_buffer_size, vertex_buffer_size)

    UploadData :: struct {
        staging_buffer:     Buffer,
        vertex_buffer:      Buffer,
        index_buffer:       Buffer,
        vertex_buffer_size: u64,
        index_buffer_size:  u64,
    }

    upload_data := UploadData{
        staging_buffer      = staging_buffer,
        vertex_buffer       = mesh.vertex_buffer,
        index_buffer        = mesh.index_buffer,
        vertex_buffer_size  = vertex_buffer_size,
        index_buffer_size   = index_buffer_size
    }

    immediate_command_submit(renderer, &upload_data, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        data := (^UploadData)(user_data)

        vertex_copy := vk.BufferCopy{
            srcOffset = 0,
            dstOffset = 0,
            size      = vk.DeviceSize(data.vertex_buffer_size),
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer.handle, data.vertex_buffer.handle, 1, &vertex_copy)

        index_copy := vk.BufferCopy{
            srcOffset = vk.DeviceSize(data.vertex_buffer_size),
            dstOffset = 0,
            size      = vk.DeviceSize(data.index_buffer_size),
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer.handle, data.index_buffer.handle, 1, &index_copy)
    })

    return mesh
}

mesh_buffers_destroy :: proc(renderer: ^Renderer, buffers: ^MeshBuffers) {
    buffer_destroy(renderer, &buffers.vertex_buffer)
    buffer_destroy(renderer, &buffers.index_buffer)
}

// Primitives

mesh_create_rectangle :: proc(renderer: ^Renderer, width, height: f32) -> ^MeshAsset {
    half_x_len := width / 2
    half_y_len := height / 2
    vertices := []MeshVertex{
        { position = {-half_x_len, -half_y_len, 0}, uv_x = 0, normal = {0, 0, 1}, uv_y = 0, color = {1, 1, 1, 1} }, // bottom-left
        { position = { half_x_len, -half_y_len, 0}, uv_x = 1, normal = {0, 0, 1}, uv_y = 0, color = {1, 1, 1, 1} }, // bottom-right
        { position = { half_x_len,  half_y_len, 0}, uv_x = 1, normal = {0, 0, 1}, uv_y = 1, color = {1, 1, 1, 1} }, // top-right
        { position = {-half_x_len,  half_y_len, 0}, uv_x = 0, normal = {0, 0, 1}, uv_y = 1, color = {1, 1, 1, 1} }, // top-left
    }
    indices := []u32{
        0, 1, 2,
        2, 3, 0,
    }

    mesh := new(MeshAsset)
    mesh.mesh_buffers = mesh_upload_to_GPU(renderer, vertices, indices)
    mesh.surfaces = []GeometricSurface{
        { start_index = 0, count = u32(len(indices)) }
    }

    return mesh
}
