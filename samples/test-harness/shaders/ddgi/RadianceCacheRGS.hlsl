#include "../include/Descriptors.hlsl"
#include "../include/Lighting.hlsl"
#include "../include/RayTracing.hlsl"
#include "../include/SpatialHash.hlsl"
#include "../include/RadianceCommon.hlsl"

#include "../../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

// ---[ Ray Generation Shader ]---

[shader("raygeneration")]
void RayGen()
{
    uint HitIndex = DispatchRaysIndex().x;
    RWStructuredBuffer<HitCachingPayload> HitCachingBuffer = GetHitCachingBuffer();
    HitCachingPayload hitPayLoad = HitCachingBuffer[HitIndex];
    if (!hitPayLoad.isActived)
    {
        return;
    }
    // Unpack the payload
    Payload payload = UnpackPayload(hitPayLoad.payload);

    // Get the acceleration structure
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);

    // Get the (dynamic) lights
    StructuredBuffer<Light> Lights = GetLights();
    // Direct Lighting and Shadowing
    float3 DirectLight = DirectDiffuseLighting(payload, GetGlobalConst(pt, rayNormalBias), GetGlobalConst(pt, rayViewBias), SceneTLAS, Lights);

    // Get the volume resources needed for the irradiance query
    // Get the DDGIVolume's index (from root/push constants)
    uint volumeIndex = GetDDGIVolumeIndex();

    // Get the DDGIVolume structured buffers
    StructuredBuffer<DDGIVolumeDescGPUPacked> DDGIVolumes = GetDDGIVolumeConstants(GetDDGIVolumeConstantsIndex());
    StructuredBuffer<DDGIVolumeResourceIndices> DDGIVolumeBindless = GetDDGIVolumeResourceIndices(GetDDGIVolumeResourceIndicesIndex());

    // Get the DDGIVolume's bindless resource indices
    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[volumeIndex];

    // Get the DDGIVolume's constants from the structured buffer
    DDGIVolumeDescGPU volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[volumeIndex]);
    
    DDGIVolumeResources resources;
    resources.probeIrradiance = GetTex2DArray(resourceIndices.probeIrradianceSRVIndex);
    resources.probeDistance = GetTex2DArray(resourceIndices.probeDistanceSRVIndex);
    resources.probeData = GetTex2DArray(resourceIndices.probeDataSRVIndex);
    resources.bilinearSampler = GetBilinearWrapSampler();

    float3 IndirectLight = EvaluateIndirectRadiance(payload.worldPosition, payload.normal, volume, SceneTLAS, resources, 64);

    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    RadianceCachingBuffer[HitIndex] = DirectLight + IndirectLight;
    HitCachingBuffer[HitIndex].isActived = false;
}