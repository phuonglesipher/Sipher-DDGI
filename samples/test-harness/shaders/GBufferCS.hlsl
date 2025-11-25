/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "include/Common.hlsl"
#include "include/Descriptors.hlsl"
#include "include/InlineRayTracingCommon.hlsl"

[numthreads(8, 8, 1)]
void CS(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 LaunchIndex = DispatchThreadID.xy;
    uint2 LaunchDimensions;
    
    // Get the lights
    StructuredBuffer<Light> Lights = GetLights();
    
    // Get the (bindless) resources
    RWTexture2D<float4> GBufferA = GetRWTex2D(GBUFFERA_INDEX);
    RWTexture2D<float4> GBufferB = GetRWTex2D(GBUFFERB_INDEX);
    RWTexture2D<float4> GBufferC = GetRWTex2D(GBUFFERC_INDEX);
    RWTexture2D<float4> GBufferD = GetRWTex2D(GBUFFERD_INDEX);
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);
    GBufferA.GetDimensions(LaunchDimensions.x, LaunchDimensions.y);
    
    // Setup the primary ray
    RayDesc ray = (RayDesc)0;
    ray.Origin = GetCamera().position;
    ray.TMin = 0.f;
    ray.TMax = 1e27f;
    
    // Pixel coordinates, remapped to [-1, 1] with y-direction flipped to match world-space
    // Camera basis, adjusted for the aspect ratio and vertical field of view
    float  px = (((float)LaunchIndex.x + 0.5f) / (float)LaunchDimensions.x) * 2.f - 1.f;
    float  py = (((float)LaunchIndex.y + 0.5f) / (float)LaunchDimensions.y) * -2.f + 1.f;
    float3 right = GetCamera().aspect * GetCamera().tanHalfFovY * GetCamera().right;
    float3 up = GetCamera().tanHalfFovY * GetCamera().up;
    
    // Compute the primary ray direction
    ray.Direction = (px * right) + (py * up) + GetCamera().forward;

    RayQuery<RAY_FLAG_NONE> RQuery;
    RQuery.TraceRayInline(SceneTLAS,
            0,
            0xFF,
            ray);
    RQuery.Proceed();
    if(RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        Payload payload;
        ShadeTriangleHit(payload, RQuery);
        // Convert albedo to sRGB before storing
        payload.albedo = LinearToSRGB(payload.albedo);
    
        // Write the GBuffer
        GBufferA[LaunchIndex] = float4(payload.albedo, COMPOSITE_FLAG_LIGHT_PIXEL);
        GBufferB[LaunchIndex] = float4(payload.worldPosition, payload.hitT);
        GBufferC[LaunchIndex] = float4(payload.normal, 1.f);
        //GBufferD[LaunchIndex] = float4(diffuse, 1.f);
    }
    else
    {
        // Convert albedo to sRGB before storing
        GBufferA[LaunchIndex] = float4(LinearToSRGB(GetGlobalConst(app, skyRadiance)), COMPOSITE_FLAG_POSTPROCESS_PIXEL);
        GBufferB[LaunchIndex].w = -1.f;
    
        // Optional clear writes. Not necessary for final image, but
        // useful for image comparisons during regression testing.
        GBufferB[LaunchIndex] = float4(0.f, 0.f, 0.f, -1.f);
        GBufferC[LaunchIndex] = float4(0.f, 0.f, 0.f, 0.f);
        GBufferD[LaunchIndex] = float4(0.f, 0.f, 0.f, 0.f);
    }
}
