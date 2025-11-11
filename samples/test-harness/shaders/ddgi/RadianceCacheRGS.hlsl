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
    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    RadianceCachingBuffer[HitIndex] = DirectLight;
    

    float3 IndirectLight = EvaluateIndirectRadiance(payload.albedo, payload.worldPosition, payload.shadingNormal, SceneTLAS, 16);
    RadianceCachingBuffer[HitIndex] += IndirectLight;
    
    RWStructuredBuffer<RadianceCacheVisualization> IndirectRadianceCachingBuffer = GetRadianceCachingVisualizationBuffer();
    IndirectRadianceCachingBuffer[HitIndex].DirectRadiance = DirectLight;
    IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance = IndirectLight;
    HitCachingBuffer[HitIndex].isActived = false;

    uint VolumeIndex = hitPayLoad.volumeIndex;
    uint RayIndex = hitPayLoad.rayIndex;
    uint ProbeIndex = hitPayLoad.probeIndex;
    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[VolumeIndex];
    RWTexture2DArray<float4> RayData = GetRWTex2DArray(resourceIndices.rayDataUAVIndex);
    DDGIVolumeDescGPU Volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[VolumeIndex]);
    uint3 outputCoords = DDGIGetRayDataTexelCoords(RayIndex, ProbeIndex, Volume);
    RWStructuredBuffer<float3> RadianceCache = GetRadianceCachingBuffer();
    float3 radiance = RadianceCache[HitIndex];
    DDGIStoreProbeRayFrontfaceHit(RayData, outputCoords, Volume, saturate(radiance), payload.hitT);
}