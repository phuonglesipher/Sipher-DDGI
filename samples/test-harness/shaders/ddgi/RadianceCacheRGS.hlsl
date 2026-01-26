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

    // Direct Lighting and Shadowing
    float3 DirectLight = DirectDiffuseLighting(payload, GetGlobalConst(pt, rayNormalBias), GetGlobalConst(pt, rayViewBias), SceneTLAS, Lights);

    RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
    RadianceCachingBuffer[HitIndex] = DirectLight;

    // Indirect lighting
    float3 IndirectLight = EvaluateIndirectRadiance(payload.albedo, payload.worldPosition, payload.shadingNormal, SceneTLAS, RADIANCE_CACHE_SAMPLE_COUNT);
    RadianceCachingBuffer[HitIndex] += IndirectLight;

    // Store visualization data
    RWStructuredBuffer<RadianceCacheVisualization> IndirectRadianceCachingBuffer = GetRadianceCachingVisualizationBuffer();
    IndirectRadianceCachingBuffer[HitIndex].DirectRadiance = DirectLight;
    IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance = IndirectLight;

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