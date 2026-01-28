/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

// ============================================================================
// ProbeRayResolveCS - Scatter cached radiance to RayData
// ============================================================================
//
// This shader resolves the world-space radiance cache to per-probe-ray RayData.
// It runs after RadianceCacheCS and before ProbeBlendingCS.
//
// For each probe ray:
//   1. Load the HashID from ProbeRayHitMap (stored by ProbeTraceCS)
//   2. If valid (not INVALID sentinel), lookup RadianceCachingBuffer[HashID]
//   3. Load hit distance from HitCachingBuffer[HashID]
//   4. Write to RayData using DDGIStoreProbeRayFrontfaceHit
//
// This ensures ALL probe rays that hit front-facing surfaces get their
// radiance from the cache, solving the "1 ray per hash cell wins" problem.
// ============================================================================

// Default defines for DDGI SDK (should be overridden by compiler defines)
#ifndef CONSTS_REGISTER
#define CONSTS_REGISTER b0
#endif

#ifndef CONSTS_SPACE
#define CONSTS_SPACE space1
#endif

#include "../include/Descriptors.hlsl"
#include "../include/SpatialHash.hlsl"

#include "../../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

// Sentinel value indicating no cache lookup needed (miss/backface/fixed ray)
#define PROBE_RAY_HIT_MAP_INVALID 0xFFFFFFFF

[numthreads(64, 1, 1)]
void CS(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint ThreadIndexInGroup : SV_GroupIndex)
{
    uint ProbeRayIndex = GroupID.x * 64 + ThreadIndexInGroup;

    // Get the DDGIVolume's index (from root/push constants)
    uint VolumeIndex = GetDDGIVolumeIndex();

    // Get the DDGIVolume structured buffers
    StructuredBuffer<DDGIVolumeDescGPUPacked> DDGIVolumes = GetDDGIVolumeConstants(GetDDGIVolumeConstantsIndex());
    StructuredBuffer<DDGIVolumeResourceIndices> DDGIVolumeBindless = GetDDGIVolumeResourceIndices(GetDDGIVolumeResourceIndicesIndex());

    // Get the DDGIVolume's constants from the structured buffer
    DDGIVolumeDescGPU Volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[VolumeIndex]);
    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[VolumeIndex];

    // Calculate total probe rays for this volume
    uint NumProbes = Volume.probeCounts.x * Volume.probeCounts.y * Volume.probeCounts.z;
    uint RaysPerProbe = Volume.probeNumRays;
    uint TotalRaysThisVolume = NumProbes * RaysPerProbe;

    // Bounds check
    if (ProbeRayIndex >= TotalRaysThisVolume)
        return;

    // Calculate ProbeIndex and RayIndex from linear index
    uint ProbeIndex = ProbeRayIndex / RaysPerProbe;
    uint RayIndex = ProbeRayIndex % RaysPerProbe;

    // Skip fixed rays - they are handled directly by ProbeTraceCS
    // Fixed rays are used for relocation/classification and don't need radiance
    if ((Volume.probeRelocationEnabled || Volume.probeClassificationEnabled) && RayIndex < RTXGI_DDGI_NUM_FIXED_RAYS)
        return;

    // Load the hash ID and hit distance for this probe ray
    // Format: .x = HashID (or INVALID), .y = asuint(HitDistance)
    RWStructuredBuffer<uint2> ProbeRayHitMapBuffer = GetProbeRayHitMap();
    uint2 HitMapData = ProbeRayHitMapBuffer[ProbeRayIndex];
    uint HashID = HitMapData.x;
    float HitDistance = asfloat(HitMapData.y);

    // Check for invalid/miss (HashID == INVALID sentinel)
    // Miss and backface rays are already handled by ProbeTraceCS
    if (HashID == PROBE_RAY_HIT_MAP_INVALID)
        return;

    // Load cached radiance from world-space radiance cache
    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    float3 CachedRadiance = RadianceCachingBuffer[HashID];

    // DEBUG: Use constant white to test if probe blending works correctly
    // If this makes the scene smoothly lit with white indirect, then probe blending is OK
    // and the issue is with RadianceCachingBuffer values
    CachedRadiance = float3(0.5, 0.5, 0.5);

    // Get RayData texture
    RWTexture2DArray<float4> RayData = GetRWTex2DArray(resourceIndices.rayDataUAVIndex);

    // Calculate output coordinates
    uint3 outputCoords = DDGIGetRayDataTexelCoords(RayIndex, ProbeIndex, Volume);

    // Store to RayData - scatter the cached radiance to this probe ray
    DDGIStoreProbeRayFrontfaceHit(RayData, outputCoords, Volume, saturate(CachedRadiance), HitDistance);
}
