struct MeshVertex
{
    float3 position;
    float  uv_x;
    float3 normal;
    float  uv_y;
    float4 color;
};

struct ParticleInstance {
    float3 position;
    float  size;
    float4 color;
};

struct GlobalSceneData {
    float4x4 viewproj;
    float4x4 view;
    float4x4 proj;
};

struct DrawPushConstants {
    float4x4          world_matrix;
    MeshVertex*       vertex_buffer;
    ParticleInstance* instance_buffer;
};

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> g_scene;

[[vk::push_constant]]
DrawPushConstants push_constants;

struct VSOutput {
    float4 position : SV_Position;
    float4 pixel_color;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VSOutput output;

    MeshVertex vertex = push_constants.vertex_buffer[vertex_id];
    ParticleInstance particle = push_constants.instance_buffer[instance_id];

    // Billboard the mesh quad toward the camera using the view matrix's rows,
    // which are the camera's world-space right/up axes.
    float3 right = g_scene.view[0].xyz;
    float3 up    = g_scene.view[1].xyz;

    float3 particle_world_pos = mul(push_constants.world_matrix, float4(particle.position, 1.0)).xyz;
    float3 world_pos = particle_world_pos + (vertex.position.x * right + vertex.position.y * up) * particle.size;

    output.position = mul(g_scene.viewproj, float4(world_pos, 1.0));
    output.pixel_color = vertex.color * particle.color;

    return output;
}

struct PSInput {
    float4 pixel_color;
};

[shader("fragment")]
float4 fragment_main(PSInput input) {
    return input.pixel_color;
}
