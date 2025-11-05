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
    float3 DirectLight = DirectDiffuseLighting(payload, GetGlobalConst(pt, rayNormalBias), GetGlobalConst(pt, rayViewBias), SceneTLAS, Lights);

    // Indirect Lighting (recursive)
    float3 surfaceBias = payload.normal;

    // Get the volume resources needed for the irradiance query
    DDGIVolumeResources resources;
    resources.probeIrradiance = GetTex2DArray(resourceIndices.probeIrradianceSRVIndex);
    resources.probeDistance = GetTex2DArray(resourceIndices.probeDistanceSRVIndex);
    resources.probeData = GetTex2DArray(resourceIndices.probeDataSRVIndex);
    resources.bilinearSampler = GetBilinearWrapSampler();

    float3 IndirectLight = float3(0.0, 0.0, 0.0);
    for (half Idx = 0; Idx < 64; Idx++)
    {
        uint Seed = HitIndex + Idx;
        float3 SamplingDirection = GetRandomDirectionOnHemisphere(payload.normal, Seed);
        RayDesc ray;
        ray.Origin = payload.worldPosition; // TODO: not using viewBias!
        ray.Direction = SamplingDirection;
        ray.TMin = 0.f;
        ray.TMax = 1e27f;

        // Trace a visibility ray
        // Skip the CHS to avoid evaluating materials
        PackedPayload packedPayload = (PackedPayload)0;
        TraceRay(
            SceneTLAS,
            RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
            0xFF,
            0,
            0,
            0,
            ray,
            packedPayload);

        if (packedPayload.hitT > 0.0f)
        {
            // Unpack the payload
            Payload TempPayload = UnpackPayload(packedPayload);
        
            // Compute volume blending weight
            float volumeBlendWeight = DDGIGetVolumeBlendWeight(TempPayload.worldPosition, volume);
        
            // Don't evaluate irradiance when the surface is outside the volume
            if (volumeBlendWeight > 0)
            {
                // Get irradiance from the DDGIVolume
                float3 irradiance = DDGIGetVolumeIrradiance(
                    TempPayload.worldPosition,
                    surfaceBias,
                    TempPayload.normal,
                    volume,
                    resources);
        
                // Attenuate irradiance by the blend weight
                irradiance *= volumeBlendWeight;
        
                float maxAlbedo = 0.9f;
                IndirectLight += ((min(TempPayload.albedo, float3(maxAlbedo, maxAlbedo, maxAlbedo)) / PI) * irradiance);
            }
        }
        else
        {
            IndirectLight += GetGlobalConst(app, skyRadiance);
        }
    }
    IndirectLight /= 64.0f;

    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    RadianceCachingBuffer[HitIndex] = DirectLight + IndirectLight;
    HitCachingBuffer[HitIndex].isActived = false;
}