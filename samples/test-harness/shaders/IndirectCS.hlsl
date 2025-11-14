/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

// -------- CONFIGURATION DEFINES -----------------------------------------------------------------

// RTXGI_DDGI_NUM_VOLUMES must be passed in as a define at shader compilation time.
// This define specifies the number of DDGIVolumes in the scene.
// Ex: RTXGI_DDGI_NUM_VOLUMES 6
#ifndef RTXGI_DDGI_NUM_VOLUMES
    #error Required define RTXGI_DDGI_NUM_VOLUMES is not defined for IndirectCS.hlsl!
#endif

// THGP_DIM_X must be passed in as a define at shader compilation time.
// This define specifies the number of threads in the thread group in the X dimension.
// Ex: THGP_DIM_X 8
#ifndef THGP_DIM_X
    #error Required define THGP_DIM_X is not defined for IndirectCS.hlsl!
#endif

// THGP_DIM_Y must be passed in as a define at shader compilation time.
// This define specifies the number of threads in the thread group in the X dimension.
// Ex: THGP_DIM_Y 4
#ifndef THGP_DIM_Y
    #error Required define THGP_DIM_Y is not defined for IndirectCS.hlsl!
#endif

// -------------------------------------------------------------------------------------------

#include "include/Common.hlsl"
#include "include/Descriptors.hlsl"
#include "include/SpatialHash.hlsl"

#include "../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

// ---[ Compute Shader ]---


float3 GetVolumeIrradiance(float3 WorldPos, float3 Normal, float3 ViewDir, float VolumeIndex)
{
    StructuredBuffer<DDGIVolumeDescGPUPacked> DDGIVolumes = GetDDGIVolumeConstants(GetDDGIVolumeConstantsIndex());
    StructuredBuffer<DDGIVolumeResourceIndices> DDGIVolumeBindless = GetDDGIVolumeResourceIndices(GetDDGIVolumeResourceIndicesIndex());
    DDGIVolumeResourceIndices resourceIndices = DDGIVolumeBindless[VolumeIndex];

    // Get the volume's constants
    DDGIVolumeDescGPU volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[VolumeIndex]);
    float3 surfaceBias = DDGIGetSurfaceBias(Normal, ViewDir, volume);

    // Get the volume's resources
    DDGIVolumeResources resources;
    resources.probeIrradiance = GetTex2DArray(resourceIndices.probeIrradianceSRVIndex);
    resources.probeDistance = GetTex2DArray(resourceIndices.probeDistanceSRVIndex);
    resources.probeData = GetTex2DArray(resourceIndices.probeDataSRVIndex);
    resources.bilinearSampler = GetBilinearWrapSampler();

    // Get the blend weight for this volume's contribution to the surface
    float blendWeight = DDGIGetVolumeBlendWeight(WorldPos, volume);
    float3 IrradianceOut = (float3)0.0f;
    //if(blendWeight > 0)
    {
        // Get irradiance for the world-space position in the volume
        IrradianceOut = DDGIGetVolumeIrradiance(
            WorldPos,
            surfaceBias,
            Normal,
            volume,
            resources);
            
        IrradianceOut *= blendWeight;
    }
    return IrradianceOut;
}

float3 GetCascadedIrradiance(float3 Pos, float3 Normal, float3 CameraPos, float BlendableStartDist)
{
    uint CurrentVolumeIndex = GetCascadeIndex(Pos, GetCascadeCount(), GetCascadeBaseDistance());
    uint NextVolumeIndex = CurrentVolumeIndex + 1;
    float3 ViewDir = (CameraPos - Pos);
    float Dist = length(ViewDir);
    ViewDir = ViewDir / Dist;
    float3 IrradianceOut = GetVolumeIrradiance(Pos, Normal, ViewDir, CurrentVolumeIndex);
    float CascadeBaseDistance = GetCascadeBaseDistance();
    float EndDist = CalculateCascadeMaxDistance(CurrentVolumeIndex, CascadeBaseDistance);
    float StartDist = EndDist - BlendableStartDist;
    float Weight = saturate((Dist - StartDist / (EndDist - StartDist)));
    if (NextVolumeIndex < GetCascadeCount() && Weight > 0.0f)
    {
        float3 IrradianceNext = GetVolumeIrradiance(Pos, Normal, ViewDir, NextVolumeIndex);
        IrradianceOut = lerp(IrradianceOut, IrradianceNext, Weight);
    }
    return IrradianceOut;
}

[numthreads(THGP_DIM_X, THGP_DIM_Y, 1)]
void CS(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    float3 color = float3(0.f, 0.f, 0.f);

    // Get the (bindless) resources
    RWTexture2D<float4> GBufferA = GetRWTex2D(GBUFFERA_INDEX);
    RWTexture2D<float4> GBufferB = GetRWTex2D(GBUFFERB_INDEX);
    RWTexture2D<float4> GBufferC = GetRWTex2D(GBUFFERC_INDEX);
    RWTexture2D<float4> DDGIOutput = GetRWTex2D(DDGI_OUTPUT_INDEX);

    // Load the albedo and primary ray hit distance
    float4 albedo = GBufferA.Load(DispatchThreadID.xy * FINAL_GATHER_DOWNSCALE);

    // Primary ray hit, need to light it
    if (albedo.a > 0.f)
    {
        // Convert albedo back to linear
        albedo.rgb = SRGBToLinear(albedo.rgb);

        // Load the world position, hit distance, and normal
        float4 worldPosHitT = GBufferB.Load(DispatchThreadID.xy * FINAL_GATHER_DOWNSCALE);
        float3 normal = GBufferC.Load(DispatchThreadID.xy * FINAL_GATHER_DOWNSCALE).xyz;
        
        // Compute final color
        color = (albedo.rgb / PI) * GetCascadedIrradiance(worldPosHitT.xyz, normal, GetCamera().position, 1.0f);
    }
    DDGIOutput[DispatchThreadID.xy] = float4(color, 1.0f);
}