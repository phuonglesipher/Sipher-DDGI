#ifndef RADIANCE_COMMON_HLSL
#define RADIANCE_COMMON_HLSL

#include "Random.hlsl"
#include "../include/Descriptors.hlsl"
#include "../include/RayTracing.hlsl"
#include "../include/Common.hlsl"
#include "../include/SpatialHash.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

float3 EvaluateIndirectRadiance(float3 Albedo, float3 WorldPosition, float3 WorldNormal, RaytracingAccelerationStructure BVH, uint SampleCount)
{
    float3 IndirectLight = float3(0.0, 0.0, 0.0);
    float3 SurfaceBias = WorldNormal + GetGlobalConst(pt, rayNormalBias);
    for (half Idx = 0; Idx < SampleCount; Idx++)
    {
        uint Seed = Idx * 10;
        float3 SamplingDirection = GetRandomDirectionOnHemisphere(WorldNormal, Seed);
        RayDesc ray;
        ray.Origin = WorldPosition + SurfaceBias; // TODO: not using viewBias!
        ray.Direction = normalize(SamplingDirection);
        ray.TMin = 0.f;
        ray.TMax = 1e27f;

        // Trace a visibility ray
        // Skip the CHS to avoid evaluating materials
        PackedPayload packedPayload = (PackedPayload)0;
        TraceRay(
            BVH,
            RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
            0xFF,
            0,
            0,
            0,
            ray,
            packedPayload);

        float3 InIrradiance = float3(0.0f, 0.0f, 0.0f);
        if (packedPayload.hitT < 0.f)
        {
            InIrradiance = GetGlobalConst(app, skyRadiance);
        }
        else
        {
            // Unpack the payload
            Payload Payloaded = UnpackPayload(packedPayload);
            uint HashID = SpatialHashCascadeIndex(Payloaded.worldPosition, GetCascadeCellRadius(), GetMaxCacheCellCount(), GetCascadeCount(), GetCascadeBaseDistance());
            RWStructuredBuffer<float3> RadianceCachingBuffer = GetRadianceCachingBuffer();
            InIrradiance = RadianceCachingBuffer[HashID];
        }

        float3 BRDF = Albedo / PI;
        float CosN = dot(WorldNormal, SamplingDirection);
        float Pdf = CosN / PI;
        IndirectLight += (BRDF * InIrradiance * CosN ) / Pdf;
    }
    IndirectLight /= SampleCount;
    return IndirectLight;
}
#endif