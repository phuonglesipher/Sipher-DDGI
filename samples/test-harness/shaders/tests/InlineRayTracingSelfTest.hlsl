/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

/**
 * Self-Test Shader for Inline Ray Tracing
 *
 * This shader performs self-validation tests that compare inline ray tracing
 * results against expected values or reference implementations. It is designed
 * to be run on actual scene data to validate the correctness of the conversion
 * from traditional TraceRay to inline RayQuery.
 *
 * Tests include:
 * - Primary ray hit consistency
 * - Visibility ray accuracy
 * - Payload data integrity
 * - Lighting calculations correctness
 *
 * Output:
 * - RWTexture2D containing test results (green = pass, red = fail)
 * - RWStructuredBuffer with detailed error metrics
 */

#include "../include/Common.hlsl"
#include "../include/Descriptors.hlsl"
#include "../include/InlineRayTracingCommon.hlsl"
#include "../include/InlineLighting.hlsl"

// Output buffers for test results
RWTexture2D<float4> TestResultImage : register(u0, space10);
RWStructuredBuffer<float4> TestMetrics : register(u1, space10);

// Test configuration constants
static const float POSITION_TOLERANCE = 0.001f;
static const float NORMAL_TOLERANCE = 0.01f;
static const float COLOR_TOLERANCE = 0.01f;
static const float DISTANCE_TOLERANCE = 0.001f;

// ============================================================================
// Self-Test: Primary Ray Hit Validation
// ============================================================================

/**
 * Test that inline ray tracing produces consistent primary ray hits.
 * Traces the same ray twice and compares results.
 */
float4 TestPrimaryRayConsistency(RayDesc ray, RaytracingAccelerationStructure SceneTLAS)
{
    // First trace
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery1;
    RQuery1.TraceRayInline(SceneTLAS, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, 0xFF, ray);
    RQuery1.Proceed();

    // Second trace (should produce identical results)
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery2;
    RQuery2.TraceRayInline(SceneTLAS, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, 0xFF, ray);
    RQuery2.Proceed();

    // Compare results
    bool status1 = (RQuery1.CommittedStatus() == COMMITTED_TRIANGLE_HIT);
    bool status2 = (RQuery2.CommittedStatus() == COMMITTED_TRIANGLE_HIT);

    if (status1 != status2)
    {
        return float4(1.0f, 0.0f, 0.0f, 1.0f); // FAIL: Inconsistent hit status
    }

    if (status1)
    {
        float hitT1 = RQuery1.CommittedRayT();
        float hitT2 = RQuery2.CommittedRayT();

        if (abs(hitT1 - hitT2) > DISTANCE_TOLERANCE)
        {
            return float4(1.0f, 0.5f, 0.0f, 1.0f); // FAIL: Inconsistent hit distance
        }

        uint instance1 = RQuery1.CommittedInstanceID();
        uint instance2 = RQuery2.CommittedInstanceID();

        if (instance1 != instance2)
        {
            return float4(1.0f, 0.0f, 0.5f, 1.0f); // FAIL: Inconsistent instance
        }
    }

    return float4(0.0f, 1.0f, 0.0f, 1.0f); // PASS
}

// ============================================================================
// Self-Test: Shading Consistency
// ============================================================================

/**
 * Test that ShadeTriangleHit produces consistent payload data.
 */
float4 TestShadingConsistency(RayDesc ray, RaytracingAccelerationStructure SceneTLAS)
{
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery;
    RQuery.TraceRayInline(SceneTLAS, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, 0xFF, ray);
    RQuery.Proceed();

    if (RQuery.CommittedStatus() != COMMITTED_TRIANGLE_HIT)
    {
        return float4(0.5f, 0.5f, 0.5f, 1.0f); // No hit (neutral)
    }

    // Shade the hit
    Payload payload;
    ShadeTriangleHit(payload, RQuery);

    // Validate payload data
    // Normal should be unit length
    float normalLength = length(payload.normal);
    if (abs(normalLength - 1.0f) > NORMAL_TOLERANCE)
    {
        return float4(1.0f, 0.0f, 0.0f, 1.0f); // FAIL: Normal not normalized
    }

    // Shading normal should be unit length
    float shadingNormalLength = length(payload.shadingNormal);
    if (abs(shadingNormalLength - 1.0f) > NORMAL_TOLERANCE)
    {
        return float4(1.0f, 0.3f, 0.0f, 1.0f); // FAIL: Shading normal not normalized
    }

    // Albedo should be in valid range
    if (any(payload.albedo < 0.0f) || any(payload.albedo > 10.0f))
    {
        return float4(1.0f, 0.6f, 0.0f, 1.0f); // FAIL: Albedo out of range
    }

    // Opacity should be in [0, 1]
    if (payload.opacity < 0.0f || payload.opacity > 1.0f)
    {
        return float4(1.0f, 0.0f, 0.3f, 1.0f); // FAIL: Opacity out of range
    }

    // hitT should match RayQuery result
    float queryHitT = RQuery.CommittedRayT();
    if (abs(payload.hitT - queryHitT) > DISTANCE_TOLERANCE)
    {
        return float4(1.0f, 0.0f, 0.6f, 1.0f); // FAIL: hitT mismatch
    }

    // World position should be on the ray
    float3 expectedPos = ray.Origin + ray.Direction * payload.hitT;
    float posError = length(payload.worldPosition - expectedPos);
    if (posError > POSITION_TOLERANCE * payload.hitT)
    {
        return float4(1.0f, 0.0f, 1.0f, 1.0f); // FAIL: Position not on ray
    }

    return float4(0.0f, 1.0f, 0.0f, 1.0f); // PASS
}

// ============================================================================
// Self-Test: Visibility Ray Accuracy
// ============================================================================

/**
 * Test visibility ray tracing for shadow calculations.
 * Verifies that visibility rays correctly detect occlusion.
 */
float4 TestVisibilityRay(float3 worldPos, float3 normal, RaytracingAccelerationStructure SceneTLAS)
{
    // Cast a ray straight up (should often be unoccluded for outdoor scenes)
    float3 upDirection = float3(0.0f, 1.0f, 0.0f);

    bool occluded1 = TraceVisibilityRayInline(
        worldPos + normal * 0.01f,
        upDirection,
        0.0f,
        1000.0f,
        SceneTLAS);

    // Cast the same ray again - should get identical results
    bool occluded2 = TraceVisibilityRayInline(
        worldPos + normal * 0.01f,
        upDirection,
        0.0f,
        1000.0f,
        SceneTLAS);

    if (occluded1 != occluded2)
    {
        return float4(1.0f, 0.0f, 0.0f, 1.0f); // FAIL: Inconsistent visibility
    }

    // Test with very short ray (should not self-intersect due to bias)
    bool selfOccluded = TraceVisibilityRayInline(
        worldPos + normal * 0.01f,
        normal,
        0.0f,
        0.001f,
        SceneTLAS);

    if (selfOccluded)
    {
        return float4(1.0f, 0.5f, 0.0f, 1.0f); // FAIL: Self-intersection detected
    }

    return float4(0.0f, 1.0f, 0.0f, 1.0f); // PASS
}

// ============================================================================
// Self-Test: Lighting Calculation Validation
// ============================================================================

/**
 * Test that lighting calculations produce valid results.
 */
float4 TestLightingCalculation(
    Payload payload,
    RaytracingAccelerationStructure SceneTLAS,
    StructuredBuffer<Light> Lights)
{
    // Calculate lighting
    float3 lighting = DirectDiffuseLightingInline(
        payload,
        0.01f,  // normalBias
        0.001f, // viewBias
        SceneTLAS,
        Lights);

    // Lighting should be non-negative
    if (any(lighting < 0.0f))
    {
        return float4(1.0f, 0.0f, 0.0f, 1.0f); // FAIL: Negative lighting
    }

    // Lighting shouldn't be infinite or NaN
    if (any(isnan(lighting)) || any(isinf(lighting)))
    {
        return float4(1.0f, 0.5f, 0.0f, 1.0f); // FAIL: Invalid lighting value
    }

    // For surfaces facing up, there should generally be some light
    // (this is a weak test, mostly checking for gross errors)
    if (payload.normal.y > 0.5f && all(lighting < 0.0001f) && HasDirectionalLight())
    {
        // This might be in shadow, which is valid
        // Return yellow to indicate potential issue worth investigating
        return float4(0.8f, 0.8f, 0.0f, 1.0f); // WARN: Upward face with no light
    }

    return float4(0.0f, 1.0f, 0.0f, 1.0f); // PASS
}

// ============================================================================
// Comprehensive Self-Test Entry Point
// ============================================================================

[numthreads(8, 8, 1)]
void CS_SelfTest(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 LaunchIndex = DispatchThreadID.xy;
    uint2 LaunchDimensions;
    TestResultImage.GetDimensions(LaunchDimensions.x, LaunchDimensions.y);

    // Early exit for out-of-bounds threads
    if (LaunchIndex.x >= LaunchDimensions.x || LaunchIndex.y >= LaunchDimensions.y) return;

    // Get resources
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);
    StructuredBuffer<Light> Lights = GetLights();

    // Setup primary ray
    float  px = (((float)LaunchIndex.x + 0.5f) / (float)LaunchDimensions.x) * 2.f - 1.f;
    float  py = (((float)LaunchIndex.y + 0.5f) / (float)LaunchDimensions.y) * -2.f + 1.f;
    float3 right = GetCamera().aspect * GetCamera().tanHalfFovY * GetCamera().right;
    float3 up = GetCamera().tanHalfFovY * GetCamera().up;

    RayDesc ray = (RayDesc)0;
    ray.Origin = GetCamera().position;
    ray.Direction = (px * right) + (py * up) + GetCamera().forward;
    ray.TMin = 0.f;
    ray.TMax = 1e27f;

    // Run tests
    float4 result = float4(0.0f, 1.0f, 0.0f, 1.0f); // Default: PASS

    // Test 1: Primary ray consistency
    float4 test1 = TestPrimaryRayConsistency(ray, SceneTLAS);
    if (test1.r > 0.5f)
    {
        result = test1;
        TestResultImage[LaunchIndex] = result;
        return;
    }

    // Test 2: Shading consistency
    float4 test2 = TestShadingConsistency(ray, SceneTLAS);
    if (test2.r > 0.5f)
    {
        result = test2;
        TestResultImage[LaunchIndex] = result;
        return;
    }

    // For remaining tests, we need a valid hit
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery;
    RQuery.TraceRayInline(SceneTLAS, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, 0xFF, ray);
    RQuery.Proceed();

    if (RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        Payload payload;
        ShadeTriangleHit(payload, RQuery);

        // Test 3: Visibility ray
        float4 test3 = TestVisibilityRay(payload.worldPosition, payload.normal, SceneTLAS);
        if (test3.r > 0.5f && test3.g < 0.5f) // Red but not yellow (warning)
        {
            result = test3;
            TestResultImage[LaunchIndex] = result;
            return;
        }

        // Test 4: Lighting calculation
        float4 test4 = TestLightingCalculation(payload, SceneTLAS, Lights);
        if (test4.r > 0.5f && test4.g < 0.5f) // Red but not yellow (warning)
        {
            result = test4;
            TestResultImage[LaunchIndex] = result;
            return;
        }

        // Check for warnings
        if (test3.r > 0.5f || test4.r > 0.5f)
        {
            result = float4(0.8f, 0.8f, 0.0f, 1.0f); // WARN
        }
    }

    TestResultImage[LaunchIndex] = result;
}

// ============================================================================
// Comparison Test: Compare Inline vs Reference GBuffer
// ============================================================================

/**
 * Compare inline-generated GBuffer against a reference GBuffer.
 * This requires the reference GBuffer to be generated first using traditional ray tracing.
 */
[numthreads(8, 8, 1)]
void CS_CompareGBuffers(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 LaunchIndex = DispatchThreadID.xy;
    uint2 LaunchDimensions;

    RWTexture2D<float4> GBufferA = GetRWTex2D(GBUFFERA_INDEX);
    RWTexture2D<float4> GBufferB = GetRWTex2D(GBUFFERB_INDEX);
    RWTexture2D<float4> GBufferC = GetRWTex2D(GBUFFERC_INDEX);

    GBufferA.GetDimensions(LaunchDimensions.x, LaunchDimensions.y);

    if (LaunchIndex.x >= LaunchDimensions.x || LaunchIndex.y >= LaunchDimensions.y) return;

    // Get resources
    RaytracingAccelerationStructure SceneTLAS = GetAccelerationStructure(SCENE_TLAS_INDEX);

    // Setup primary ray
    float  px = (((float)LaunchIndex.x + 0.5f) / (float)LaunchDimensions.x) * 2.f - 1.f;
    float  py = (((float)LaunchIndex.y + 0.5f) / (float)LaunchDimensions.y) * -2.f + 1.f;
    float3 right = GetCamera().aspect * GetCamera().tanHalfFovY * GetCamera().right;
    float3 up = GetCamera().tanHalfFovY * GetCamera().up;

    RayDesc ray = (RayDesc)0;
    ray.Origin = GetCamera().position;
    ray.Direction = (px * right) + (py * up) + GetCamera().forward;
    ray.TMin = 0.f;
    ray.TMax = 1e27f;

    // Trace with inline ray tracing
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery;
    RQuery.TraceRayInline(SceneTLAS, RAY_FLAG_CULL_BACK_FACING_TRIANGLES, 0xFF, ray);
    RQuery.Proceed();

    float4 result = float4(0.0f, 1.0f, 0.0f, 1.0f); // Default: PASS

    // Load reference GBuffer data
    float4 refGBufferA = GBufferA[LaunchIndex];
    float4 refGBufferB = GBufferB[LaunchIndex];
    float4 refGBufferC = GBufferC[LaunchIndex];

    float refHitT = refGBufferB.w;
    bool refHit = (refHitT > 0.0f);
    bool inlineHit = (RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT);

    // Compare hit status
    if (refHit != inlineHit)
    {
        result = float4(1.0f, 0.0f, 0.0f, 1.0f); // FAIL: Hit status mismatch
        TestResultImage[LaunchIndex] = result;
        return;
    }

    if (inlineHit)
    {
        Payload payload;
        ShadeTriangleHit(payload, RQuery);

        // Compare hit distance
        float hitTError = abs(payload.hitT - refHitT);
        if (hitTError > DISTANCE_TOLERANCE)
        {
            result = float4(1.0f, hitTError, 0.0f, 1.0f); // FAIL: Hit distance mismatch
            TestResultImage[LaunchIndex] = result;
            return;
        }

        // Compare world position
        float3 refWorldPos = refGBufferB.xyz;
        float posError = length(payload.worldPosition - refWorldPos);
        if (posError > POSITION_TOLERANCE * payload.hitT)
        {
            result = float4(1.0f, 0.5f, posError, 1.0f); // FAIL: Position mismatch
            TestResultImage[LaunchIndex] = result;
            return;
        }

        // Compare normal
        float3 refNormal = refGBufferC.xyz;
        float normalError = length(payload.normal - refNormal);
        if (normalError > NORMAL_TOLERANCE)
        {
            result = float4(1.0f, 0.0f, 0.5f, 1.0f); // FAIL: Normal mismatch
            TestResultImage[LaunchIndex] = result;
            return;
        }

        // Compare albedo (approximate due to sRGB conversion)
        float3 refAlbedo = refGBufferA.xyz;
        float3 inlineAlbedoSRGB = LinearToSRGB(payload.albedo);
        float albedoError = length(inlineAlbedoSRGB - refAlbedo);
        if (albedoError > COLOR_TOLERANCE)
        {
            result = float4(0.8f, 0.8f, 0.0f, 1.0f); // WARN: Albedo difference
        }
    }

    TestResultImage[LaunchIndex] = result;
}

// ============================================================================
// Statistics Collection
// ============================================================================

groupshared uint s_passCount;
groupshared uint s_failCount;
groupshared uint s_warnCount;

[numthreads(8, 8, 1)]
void CS_CollectStatistics(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 LaunchIndex = DispatchThreadID.xy;
    uint2 LaunchDimensions;
    TestResultImage.GetDimensions(LaunchDimensions.x, LaunchDimensions.y);

    // Initialize shared memory
    if (GroupThreadID.x == 0 && GroupThreadID.y == 0)
    {
        s_passCount = 0;
        s_failCount = 0;
        s_warnCount = 0;
    }
    GroupMemoryBarrierWithGroupSync();

    if (LaunchIndex.x < LaunchDimensions.x && LaunchIndex.y < LaunchDimensions.y)
    {
        float4 testResult = TestResultImage[LaunchIndex];

        if (testResult.g > 0.9f && testResult.r < 0.1f)
        {
            InterlockedAdd(s_passCount, 1);
        }
        else if (testResult.r > 0.9f)
        {
            InterlockedAdd(s_failCount, 1);
        }
        else
        {
            InterlockedAdd(s_warnCount, 1);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    // Write group statistics
    if (GroupThreadID.x == 0 && GroupThreadID.y == 0)
    {
        uint groupIndex = GroupID.y * (LaunchDimensions.x / 8) + GroupID.x;
        TestMetrics[groupIndex] = float4(
            (float)s_passCount,
            (float)s_failCount,
            (float)s_warnCount,
            0.0f
        );
    }
}
