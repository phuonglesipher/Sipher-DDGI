/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "../include/Descriptors.hlsl"
#include "../include/Lighting.hlsl"
#include "../include/RayTracing.hlsl"
#include "../include/SpatialHash.hlsl"

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
    // Get the DDGIVolume's index (from root/push constants)
    uint volumeIndex = GetDDGIVolumeIndex();

    // Get the DDGIVolume structured buffers
    StructuredBuffer<DDGIVolumeDescGPUPacked> DDGIVolumes = GetDDGIVolumeConstants(GetDDGIVolumeConstantsIndex());
    StructuredBuffer<DDGIVolumeResourceIndices> DDGIVolumeBindless = GetDDGIVolumeResourceIndices(GetDDGIVolumeResourceIndicesIndex());

    // Get the DDGIVolume's bindless resource indices
    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[volumeIndex];

    // Get the DDGIVolume's constants from the structured buffer
    DDGIVolumeDescGPU volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[volumeIndex]);
    
    // Unpack the payload
    Payload payload = UnpackPayload(hitPayLoad.payload);

    // Get the acceleration structure
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);

    // Get the (dynamic) lights
    StructuredBuffer<Light> Lights = GetLights();

    // Direct Lighting and Shadowing
    float3 diffuse = DirectDiffuseLighting(payload, GetGlobalConst(pt, rayNormalBias), GetGlobalConst(pt, rayViewBias), SceneTLAS, Lights);

    // Indirect Lighting (recursive)
    float3 irradiance = 0.f;
    float3 surfaceBias = float3(0.0f, 0.0f, 0.0f);

    // Get the volume resources needed for the irradiance query
    DDGIVolumeResources resources;
    resources.probeIrradiance = GetTex2DArray(resourceIndices.probeIrradianceSRVIndex);
    resources.probeDistance = GetTex2DArray(resourceIndices.probeDistanceSRVIndex);
    resources.probeData = GetTex2DArray(resourceIndices.probeDataSRVIndex);
    resources.bilinearSampler = GetBilinearWrapSampler();

    // Compute volume blending weight
    float volumeBlendWeight = DDGIGetVolumeBlendWeight(payload.worldPosition, volume);

    // Don't evaluate irradiance when the surface is outside the volume
    if (volumeBlendWeight > 0)
    {
        // Get irradiance from the DDGIVolume
        irradiance = DDGIGetVolumeIrradiance(
            payload.worldPosition,
            surfaceBias,
            payload.normal,
            volume,
            resources);

        // Attenuate irradiance by the blend weight
        irradiance *= volumeBlendWeight;
    }

    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();

    // Perfectly diffuse reflectors don't exist in the real world.
    // Limit the BRDF albedo to a maximum value to account for the energy loss at each bounce.
    float maxAlbedo = 0.9f;

    // Store the final ray radiance and hit distance
    float3 radiance = diffuse + ((min(payload.albedo, float3(maxAlbedo, maxAlbedo, maxAlbedo)) / PI) * irradiance);
    RadianceCachingBuffer[HitIndex] = radiance;
    HitCachingBuffer[HitIndex].isActived = false;
}
