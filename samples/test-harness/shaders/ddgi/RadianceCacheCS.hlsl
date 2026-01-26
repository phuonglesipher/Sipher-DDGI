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
    // Hybrid Linear/Exponential Accumulation (idTech8/SHaRC-inspired)
    //
    // Phase 1 (Linear): blend = 1/N where N is sample count (fast convergence)
    // Phase 2 (Exponential): blend = 1/MAX_SAMPLES (temporal stability)
    //
    // Without explicit sample count storage, we estimate effective sample count
    // from luminance stability. When scene changes significantly, we "reset"
    // to linear accumulation.
    // ============================================================================
    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    float3 OldRadiance = RadianceCachingBuffer[HitIndex];

    // Compute luminance for stability detection
    float OldLuminance = dot(OldRadiance, float3(0.299f, 0.587f, 0.114f));
    float NewLuminance = dot(NewRadiance, float3(0.299f, 0.587f, 0.114f));

    float BlendFactor;

#if RADIANCE_CACHE_FIXED_BLEND_MODE
    // Fixed blend mode: always use 1/MAX_SAMPLES for maximum stability
    // This is the "converged" state - very slow adaptation but no flickering
    BlendFactor = 1.0f / RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES;
#else
    // Adaptive mode: estimate effective sample count from luminance stability
    float RelativeChange = abs(NewLuminance - OldLuminance) / max(OldLuminance, 0.001f);

    // - High change (>threshold) → low sample count → high blend (linear phase)
    // - Low change → high sample count → low blend (exponential phase)
    float StabilityFactor = saturate(1.0f - RelativeChange / RADIANCE_CACHE_CHANGE_THRESHOLD);
    float EffectiveSampleCount = lerp(1.0f, RADIANCE_CACHE_MAX_ACCUMULATED_SAMPLES, StabilityFactor);

    // Blend factor: 1/N mimics linear accumulation, capped at 1/MAX for exponential phase
    BlendFactor = 1.0f / EffectiveSampleCount;
#endif

    // For uninitialized cells (near-zero luminance), use new value directly
    if (OldLuminance < 0.0001f)
    {
        BlendFactor = 1.0f;
    }

    // Blend with history
    float3 FinalRadiance = lerp(OldRadiance, NewRadiance, BlendFactor);
    RadianceCachingBuffer[HitIndex] = FinalRadiance;

    // ============================================================================
    // Visualization with same hybrid blending
    // ============================================================================
    RWStructuredBuffer<RadianceCacheVisualization> IndirectRadianceCachingBuffer = GetRadianceCachingVisualizationBuffer();
    float3 OldDirectRadiance = IndirectRadianceCachingBuffer[HitIndex].DirectRadiance;
    float3 OldIndirectRadiance = IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance;

    IndirectRadianceCachingBuffer[HitIndex].DirectRadiance = lerp(OldDirectRadiance, DirectLight, BlendFactor);
    IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance = lerp(OldIndirectRadiance, IndirectLight, BlendFactor);

    // Store radiance to DDGI ray data
    uint VolumeIndex = hitData.VolumeIndex;
    uint RayIndex = hitData.RayIndex;
    uint ProbeIndex = hitData.ProbeIndex;

    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[VolumeIndex];
    RWTexture2DArray<float4> RayData = GetRWTex2DArray(resourceIndices.rayDataUAVIndex);
    DDGIVolumeDescGPU Volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[VolumeIndex]);
    uint3 outputCoords = DDGIGetRayDataTexelCoords(RayIndex, ProbeIndex, Volume);

    float3 radiance = RadianceCachingBuffer[HitIndex];
    DDGIStoreProbeRayFrontfaceHit(RayData, outputCoords, Volume, saturate(radiance), hitData.HitDistance);
}
