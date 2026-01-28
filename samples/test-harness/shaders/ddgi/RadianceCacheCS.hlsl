/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

// Default defines for DDGI SDK (should be overridden by compiler defines)
#ifndef CONSTS_REGISTER
#define CONSTS_REGISTER b0
#endif

#ifndef CONSTS_SPACE
#define CONSTS_SPACE space1
#endif

#ifndef RADIANCE_CACHE_SAMPLE_COUNT
#define RADIANCE_CACHE_SAMPLE_COUNT 8
#endif

// ============================================================================
// Temporal Stability Parameters (idTech8/SHaRC-inspired)
// ============================================================================
// The approach: linear accumulation for first N samples, then exponential blend
// This provides fast convergence initially, then temporal stability
//
// MAX_ACCUMULATED_SAMPLES: After this many samples, switch to exponential blend
// - Higher = more stable but slower to react to lighting changes
// - Lower = faster reaction but more noise
// - idTech8/Bevy Solari uses 32 samples
#ifndef RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES
#define RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES 32.0f
#endif

// CHANGE_THRESHOLD: Relative luminance change that triggers "reset"
// - When lighting changes significantly, reset to linear accumulation
// - 1.0 = 100% change considered significant (more stable)
#ifndef RADIANCE_CACHE_CHANGE_THRESHOLD
#define RADIANCE_CACHE_CHANGE_THRESHOLD 1.0f
#endif

// FIXED_BLEND_MODE: Use fixed blend factor instead of adaptive
// - 1 = use fixed blend of 1/MAX_ACCUMULATED_SAMPLES (most stable)
// - 0 = use adaptive blend based on luminance change
#ifndef RADIANCE_CACHE_FIXED_BLEND_MODE
#define RADIANCE_CACHE_FIXED_BLEND_MODE 1
#endif

// UPDATE_JITTER: Temporal spreading to reduce race conditions
// - Each cell only updates when (HashID + frameNumber) % UPDATE_JITTER == 0
// - Reduces chance of multiple threads writing same cell in same frame
// - Higher value = more stable but slower convergence
// - 1 = no jittering (all cells update every frame)
#ifndef RADIANCE_CACHE_UPDATE_JITTER
#define RADIANCE_CACHE_UPDATE_JITTER 4
#endif

// USE_ATOMIC_ACCUMULATION: Use SHaRC-style atomic operations
// - 1 = use InterlockedAdd for thread-safe accumulation (recommended)
// - 0 = use temporal jittering (simpler fallback)
#ifndef RADIANCE_CACHE_USE_ATOMIC_ACCUMULATION
#define RADIANCE_CACHE_USE_ATOMIC_ACCUMULATION 1
#endif

// RADIANCE_SCALE: Scale factor for converting float radiance to integer for atomics
// Higher = more precision, but risk of overflow
// SHaRC uses different scales, we use 1024 as a safe default
#ifndef RADIANCE_CACHE_RADIANCE_SCALE
#define RADIANCE_CACHE_RADIANCE_SCALE 1024.0f
#endif

// ============================================================================
// Collision Detection Parameters (idTech8/SHaRC-style)
// ============================================================================
// USE_COLLISION_DETECTION: Enable checksum-based collision detection
// - 1 = detect and handle hash collisions using checksums (recommended)
// - 0 = disable collision detection (faster but may have light bleeding)
// TEMPORARILY DISABLED: Checksum mismatch due to FP precision between
// ProbeTraceCS (ray equation position) and RadianceCacheCS (interpolated vertex position)
#ifndef RADIANCE_CACHE_USE_COLLISION_DETECTION
#define RADIANCE_CACHE_USE_COLLISION_DETECTION 0
#endif

// MAX_ENTRY_AGE: Maximum age (in frames) before an entry can be evicted
// - Higher = more stable for static scenes
// - Lower = faster adaptation for dynamic scenes
// - idTech8 uses 8-16 frames typically
#ifndef RADIANCE_CACHE_MAX_ENTRY_AGE
#define RADIANCE_CACHE_MAX_ENTRY_AGE 8
#endif

// COLLISION_EVICT_THRESHOLD: Age threshold for eviction on collision
// - If existing entry is older than this, evict it for new entry
// - Should be <= MAX_ENTRY_AGE
#ifndef RADIANCE_CACHE_COLLISION_EVICT_THRESHOLD
#define RADIANCE_CACHE_COLLISION_EVICT_THRESHOLD 4
#endif

#include "../include/Descriptors.hlsl"
#include "../include/InlineLighting.hlsl"
#include "../include/InlineRayTracingCommon.hlsl"
#include "../include/SpatialHash.hlsl"
#include "../include/RadianceCommon.hlsl"

#include "../../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

// ============================================================================
// Inline Indirect Radiance Evaluation
// ============================================================================

/**
 * Evaluate indirect radiance using inline ray tracing for visibility testing.
 */
float3 EvaluateIndirectRadianceInline(float3 Albedo, float3 WorldPosition, float3 WorldNormal, RaytracingAccelerationStructure BVH, uint SampleCount)
{
    float3 IndirectLight = float3(0.0, 0.0, 0.0);
    float3 SurfaceBias = WorldNormal * GetGlobalConst(pt, rayNormalBias);

    for (uint Idx = 0; Idx < SampleCount; Idx++)
    {
        // Fully deterministic seed - no frame number dependency
        // Each cache cell always samples the exact same directions for stability
        uint Seed = asuint(WorldPosition.x) ^ asuint(WorldPosition.y) ^ asuint(WorldPosition.z);
        Seed = WangHash(Seed + Idx * 17);
        float3 SamplingDirection = GetRandomDirectionOnHemisphere(WorldNormal, Seed);

        RayDesc ray;
        ray.Origin = WorldPosition + SurfaceBias;
        ray.Direction = normalize(SamplingDirection);
        ray.TMin = 0.f;
        ray.TMax = 1e27f;

        // Trace a visibility ray using inline ray tracing
        RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> RQuery;
        RQuery.TraceRayInline(
            BVH,
            RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
            0xFF,
            ray);
        RQuery.Proceed();

        float3 InIrradiance = float3(0.0f, 0.0f, 0.0f);

        if (RQuery.CommittedStatus() != COMMITTED_TRIANGLE_HIT)
        {
            // Ray missed - use sky radiance
            InIrradiance = GetGlobalConst(app, skyRadiance);
        }
        else
        {
            // Ray hit - compute hit position and sample radiance cache
            float hitT = RQuery.CommittedRayT();
            float3 hitPosition = WorldPosition + SurfaceBias + ray.Direction * hitT;

            uint HashID = SpatialHashCascadeIndex(hitPosition, GetCascadeCellRadius(), GetMaxCacheCellCount(), GetCascadeCount(), GetCascadeBaseDistance());
            RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
            InIrradiance = RadianceCachingBuffer[HashID];
        }

        float3 BRDF = Albedo / PI;
        float CosN = max(dot(WorldNormal, SamplingDirection), 0.0f);
        float Pdf = CosN / PI;

        if (Pdf > 0.0001f)
        {
            IndirectLight += (BRDF * InIrradiance * CosN) / Pdf;
        }
    }

    IndirectLight /= (float)SampleCount;
    return IndirectLight;
}

// ============================================================================
// Compute Shader Entry Point
// ============================================================================

[numthreads(64, 1, 1)]
void CS(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint ThreadIndexInGroup : SV_GroupIndex)
{
    uint HitIndex = GroupID.x * 64 + ThreadIndexInGroup;

    RWStructuredBuffer<HitPackedData> HitCachingBuffer = GetHitCachingBuffer();
    HitPackedData packedHitData = HitCachingBuffer[HitIndex];

    // Unpack hit data
    HitUnpackedData hitData;
    UnpackData(packedHitData, hitData);

    // Skip inactive entries (check if primitive index is valid)
    if (hitData.PrimitiveIndex == 0 && hitData.InstanceIndex == 0 && hitData.HitDistance == 0.0f)
    {
        return;
    }

    // Get the acceleration structure
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);

    // Get the (dynamic) lights
    StructuredBuffer<Light> Lights = GetLights();

    // Load geometry data for the hit
    GeometryData geometry;
    GetGeometryData(hitData.InstanceIndex, hitData.GeometryIndex, geometry);

    // Load and interpolate vertex data
    Vertex vertices[3];
    LoadVertices(hitData.InstanceIndex, hitData.PrimitiveIndex, geometry, vertices);

    float3 barycentrics = float3(1.f - hitData.Barycentrics.x - hitData.Barycentrics.y, hitData.Barycentrics.x, hitData.Barycentrics.y);
    Vertex v = InterpolateVertex(vertices, barycentrics);

    // Get instance transform
    TLASInstance instance = GetTLASInstances()[hitData.InstanceIndex];
    float3x4 objectToWorld = instance.transform;

    // Create payload from hit data
    Payload payload = (Payload)0;
    payload.hitT = hitData.HitDistance;
    payload.worldPosition = mul(objectToWorld, float4(v.position, 1.f)).xyz;
    payload.normal = normalize(mul(objectToWorld, float4(v.normal, 0.f)).xyz);
    payload.shadingNormal = payload.normal;

    // Load material
    Material material = GetMaterial(geometry);
    payload.albedo = material.albedo;
    payload.opacity = material.opacity;

    // Sample textures (use fixed LOD for probe rays)
    if (material.albedoTexIdx > -1)
    {
        uint width, height, numLevels;
        GetTex2D(material.albedoTexIdx).GetDimensions(0, width, height, numLevels);
        float4 bco = GetTex2D(material.albedoTexIdx).SampleLevel(GetBilinearWrapSampler(), v.uv0, numLevels / 2.f);
        payload.albedo *= bco.rgb;
        payload.opacity *= bco.a;
    }

    if (material.normalTexIdx > -1)
    {
        uint width, height, numLevels;
        GetTex2D(material.normalTexIdx).GetDimensions(0, width, height, numLevels);
        float3 tangent = normalize(mul(objectToWorld, float4(v.tangent.xyz, 0.f)).xyz);
        float3 bitangent = cross(payload.normal, tangent) * v.tangent.w;
        float3x3 TBN = { tangent, bitangent, payload.normal };
        payload.shadingNormal = GetTex2D(material.normalTexIdx).SampleLevel(GetBilinearWrapSampler(), v.uv0, numLevels / 2.f).xyz;
        payload.shadingNormal = (payload.shadingNormal * 2.f) - 1.f;
        payload.shadingNormal = mul(payload.shadingNormal, TBN);
    }

    // Direct Lighting and Shadowing using inline ray tracing
    float3 DirectLight = DirectDiffuseLightingInline(payload, GetGlobalConst(pt, rayNormalBias), GetGlobalConst(pt, rayViewBias), SceneTLAS, Lights);

    // Indirect lighting using inline ray tracing
    float3 IndirectLight = EvaluateIndirectRadianceInline(payload.albedo, payload.worldPosition, payload.shadingNormal, SceneTLAS, RADIANCE_CACHE_SAMPLE_COUNT);

    // Compute new radiance for this frame
    float3 NewRadiance = DirectLight + IndirectLight;

    // ============================================================================
    // Spatial Hash Indexing with Checksum (SHaRC-style collision detection)
    // ============================================================================
    // IMPORTANT: Use HitIndex (original HashID from ProbeTraceCS) for RadianceCachingBuffer
    // to ensure consistency with ProbeRayResolveCS. Only use recalculated Checksum for
    // collision detection.
    uint RecalculatedHashID;
    uint Checksum;
    SpatialHashCascadeIndexWithChecksum(
        payload.worldPosition,
        GetCascadeCellRadius(),
        GetMaxCacheCellCount(),
        GetCascadeCount(),
        GetCascadeBaseDistance(),
        RecalculatedHashID,
        Checksum
    );

    // Use HitIndex as the canonical hash ID (matches ProbeTraceCS and ProbeRayResolveCS)
    uint HashID = HitIndex;

    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    float3 FinalRadiance;

#if RADIANCE_CACHE_USE_ATOMIC_ACCUMULATION
    // ============================================================================
    // SHaRC-style Atomic Accumulation with Collision Detection (idTech8-inspired)
    // ============================================================================
    RWByteAddressBuffer AccumulationBuffer = GetRadianceCacheAccumulationByteBuffer();
    RWByteAddressBuffer MetadataBuffer = GetRadianceCacheMetadataBuffer();

    // Calculate byte offsets using HitIndex (original HashID)
    // Accumulation: 16 bytes per entry (R, G, B, Count)
    // Metadata: 8 bytes per entry (Checksum, Age)
    uint AccumByteOffset = HitIndex * 16;
    uint MetaByteOffset = HitIndex * 8;

    // ============================================================================
    // Collision Detection (idTech8/SHaRC-style)
    // Uses frame number instead of age counter to avoid needing separate age increment pass
    // ============================================================================
    bool bSkipAccumulation = false;

#if RADIANCE_CACHE_USE_COLLISION_DETECTION
    uint CurrentFrame = GetGlobalConst(app, frameNumber);

    // Read stored checksum and last update frame
    uint StoredChecksum = MetadataBuffer.Load(MetaByteOffset + 0);
    uint StoredFrame = MetadataBuffer.Load(MetaByteOffset + 4);

    // Calculate age as frames since last update
    uint Age = CurrentFrame - StoredFrame;

    bool IsEmpty = (StoredChecksum == 0);
    bool IsSameCell = (StoredChecksum == Checksum);
    bool IsCollision = !IsEmpty && !IsSameCell;

    if (IsCollision)
    {
        // Collision detected - check if we should evict the old entry
        if (Age >= RADIANCE_CACHE_COLLISION_EVICT_THRESHOLD)
        {
            // Old entry is stale, evict it and take over this slot
            // Reset accumulation buffer for this cell
            AccumulationBuffer.Store4(AccumByteOffset, uint4(0, 0, 0, 0));
            // Update metadata with new checksum and current frame
            MetadataBuffer.Store(MetaByteOffset + 0, Checksum);
            MetadataBuffer.Store(MetaByteOffset + 4, CurrentFrame);
            // Clear radiance history
            RadianceCachingBuffer[HashID] = float3(0, 0, 0);
        }
        else
        {
            // Existing entry is recent, skip this update to avoid light bleeding
            // Still need to output something for DDGI
            FinalRadiance = RadianceCachingBuffer[HashID];
            bSkipAccumulation = true;
        }
    }
    else if (IsEmpty)
    {
        // First write to this cell - claim it
        MetadataBuffer.Store(MetaByteOffset + 0, Checksum);
        MetadataBuffer.Store(MetaByteOffset + 4, CurrentFrame);
    }
    else // IsSameCell
    {
        // Same cell, update frame to mark as recently used
        MetadataBuffer.Store(MetaByteOffset + 4, CurrentFrame);
    }
#endif // RADIANCE_CACHE_USE_COLLISION_DETECTION

    if (!bSkipAccumulation)
    {
        // Scale radiance to integers for atomic operations
        uint3 ScaledRadiance = uint3(saturate(NewRadiance) * RADIANCE_CACHE_RADIANCE_SCALE);

        // Atomic add - thread-safe accumulation
        uint OriginalR, OriginalG, OriginalB, OriginalCount;
        AccumulationBuffer.InterlockedAdd(AccumByteOffset + 0, ScaledRadiance.x, OriginalR);
        AccumulationBuffer.InterlockedAdd(AccumByteOffset + 4, ScaledRadiance.y, OriginalG);
        AccumulationBuffer.InterlockedAdd(AccumByteOffset + 8, ScaledRadiance.z, OriginalB);
        AccumulationBuffer.InterlockedAdd(AccumByteOffset + 12, 1u, OriginalCount);

        // Read back accumulated values (after our add)
        uint NewR = OriginalR + ScaledRadiance.x;
        uint NewG = OriginalG + ScaledRadiance.y;
        uint NewB = OriginalB + ScaledRadiance.z;
        uint NewCount = OriginalCount + 1;

        float SampleCount = max((float)NewCount, 1.0f);

        // Compute average radiance from accumulated samples
        float3 AccumulatedRadiance = float3(NewR, NewG, NewB) / (RADIANCE_CACHE_RADIANCE_SCALE * SampleCount);

        // Blend accumulated radiance with resolved history
        float3 OldRadiance = RadianceCachingBuffer[HashID];
        float BlendFactor = 1.0f / min(SampleCount, RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES);

        // For first sample, use new value directly
        if (SampleCount <= 1.0f)
        {
            BlendFactor = 1.0f;
        }

        FinalRadiance = lerp(OldRadiance, AccumulatedRadiance, BlendFactor);
        RadianceCachingBuffer[HashID] = FinalRadiance;
    }

#else
    // ============================================================================
    // Non-atomic fallback with temporal jittering
    // ============================================================================
    float3 OldRadiance = RadianceCachingBuffer[HashID];
    uint FrameNumber = GetGlobalConst(app, frameNumber);
    bool ShouldUpdate = ((HashID + FrameNumber) % RADIANCE_CACHE_UPDATE_JITTER) == 0;

    FinalRadiance = OldRadiance; // Default: keep old value

    if (ShouldUpdate)
    {
        float OldLuminance = dot(OldRadiance, float3(0.299f, 0.587f, 0.114f));
        float BlendFactor = (float)RADIANCE_CACHE_UPDATE_JITTER / RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES;

        if (OldLuminance < 0.0001f)
        {
            BlendFactor = 1.0f;
        }

        FinalRadiance = lerp(OldRadiance, NewRadiance, BlendFactor);
        RadianceCachingBuffer[HashID] = FinalRadiance;
    }
#endif

    // ============================================================================
    // Visualization buffer (still uses HitIndex for per-ray debugging)
    // Uses fixed blend factor for stability
    // ============================================================================
    float VisualizationBlend = 1.0f / RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES;
    RWStructuredBuffer<RadianceCacheVisualization> IndirectRadianceCachingBuffer = GetRadianceCachingVisualizationBuffer();
    float3 OldDirectRadiance = IndirectRadianceCachingBuffer[HitIndex].DirectRadiance;
    float3 OldIndirectRadiance = IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance;

    IndirectRadianceCachingBuffer[HitIndex].DirectRadiance = lerp(OldDirectRadiance, DirectLight, VisualizationBlend);
    IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance = lerp(OldIndirectRadiance, IndirectLight, VisualizationBlend);

    // NOTE: RayData write has been moved to ProbeRayResolveCS
    // This shader now only writes to the world-space RadianceCachingBuffer
    // ProbeRayResolveCS scatters the cached radiance to all probe rays via ProbeRayHitMap
}
