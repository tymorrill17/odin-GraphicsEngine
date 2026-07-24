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
    float3 velocity;
    float4 color;
};

struct GlobalSceneData {
    float4x4 view;
    float4x4 proj;
    float4x4 viewproj;
};

[[vk::binding(0, 0)]]
ConstantBuffer<GlobalSceneData> g_scene;

struct PSInput {
    float4 pixel_color;
};

[shader("fragment")]
float4 fragment_main(PSInput input) {
    return input.pixel_color;
}


