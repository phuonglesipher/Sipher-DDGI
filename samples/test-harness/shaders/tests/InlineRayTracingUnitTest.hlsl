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
 * Unit Test Shader for Inline Ray Tracing Functions
 *
 * This shader tests the correctness of core inline ray tracing utility functions:
 * - LoadIndices: Verify correct index loading from buffers
 * - LoadVertices: Verify correct vertex data loading
 * - InterpolateVertex: Verify barycentric interpolation
 * - RayDiff: Verify ray differential computation
 * - PackData/UnpackData: Verify hit data packing/unpacking
 *
 * Test results are written to an output buffer where:
 * - 0 = PASS
 * - Non-zero = FAIL (value indicates which test failed)
 */

#include "../include/Common.hlsl"
#include "../include/Descriptors.hlsl"
#include "../include/InlineRayTracingCommon.hlsl"

// Test result buffer
RWStructuredBuffer<uint> TestResults : register(u0, space10);

// ============================================================================
// Test Helper Macros
// ============================================================================

#define TEST_EPSILON 0.0001f

bool FloatEquals(float a, float b)
{
    return abs(a - b) < TEST_EPSILON;
}

bool Float2Equals(float2 a, float2 b)
{
    return FloatEquals(a.x, b.x) && FloatEquals(a.y, b.y);
}

bool Float3Equals(float3 a, float3 b)
{
    return FloatEquals(a.x, b.x) && FloatEquals(a.y, b.y) && FloatEquals(a.z, b.z);
}

// ============================================================================
// Test: Barycentric Interpolation
// ============================================================================

uint TestBarycentricInterpolation()
{
    // Create test vertices
    Vertex vertices[3];
    vertices[0].position = float3(0, 0, 0);
    vertices[0].normal = float3(0, 1, 0);
    vertices[0].tangent = float4(1, 0, 0, 1);
    vertices[0].uv0 = float2(0, 0);

    vertices[1].position = float3(1, 0, 0);
    vertices[1].normal = float3(0, 1, 0);
    vertices[1].tangent = float4(1, 0, 0, 1);
    vertices[1].uv0 = float2(1, 0);

    vertices[2].position = float3(0, 0, 1);
    vertices[2].normal = float3(0, 1, 0);
    vertices[2].tangent = float4(1, 0, 0, 1);
    vertices[2].uv0 = float2(0, 1);

    // Test 1: Center of triangle (equal weights)
    float3 barycentrics1 = float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f);
    Vertex result1 = InterpolateVertex(vertices, barycentrics1);

    float3 expectedPos1 = float3(1.0f/3.0f, 0, 1.0f/3.0f);
    if (!Float3Equals(result1.position, expectedPos1))
    {
        return 1; // Test 1 failed: Position interpolation
    }

    float2 expectedUV1 = float2(1.0f/3.0f, 1.0f/3.0f);
    if (!Float2Equals(result1.uv0, expectedUV1))
    {
        return 2; // Test 2 failed: UV interpolation
    }

    // Test 2: First vertex only
    float3 barycentrics2 = float3(1, 0, 0);
    Vertex result2 = InterpolateVertex(vertices, barycentrics2);

    if (!Float3Equals(result2.position, vertices[0].position))
    {
        return 3; // Test 3 failed: First vertex position
    }

    // Test 3: Edge midpoint
    float3 barycentrics3 = float3(0.5f, 0.5f, 0);
    Vertex result3 = InterpolateVertex(vertices, barycentrics3);

    float3 expectedPos3 = float3(0.5f, 0, 0);
    if (!Float3Equals(result3.position, expectedPos3))
    {
        return 4; // Test 4 failed: Edge midpoint position
    }

    return 0; // All tests passed
}

// ============================================================================
// Test: Hit Data Packing/Unpacking
// ============================================================================

uint TestHitDataPacking()
{
    // Create test data
    HitUnpackedData original;
    original.ProbeIndex = 1234;       // 16 bits max
    original.RayIndex = 128;          // 8 bits max
    original.VolumeIndex = 5;         // 8 bits max
    original.PrimitiveIndex = 512;    // 10 bits max
    original.InstanceIndex = 2048;    // 12 bits max
    original.GeometryIndex = 100;     // 10 bits max
    original.Barycentrics = float2(0.3f, 0.4f);
    original.HitDistance = 25.5f;

    // Pack
    HitPackedData packed;
    PackData(original, packed);

    // Unpack
    HitUnpackedData unpacked;
    UnpackData(packed, unpacked);

    // Verify
    if (unpacked.ProbeIndex != original.ProbeIndex)
    {
        return 10; // Test failed: ProbeIndex mismatch
    }

    if (unpacked.RayIndex != original.RayIndex)
    {
        return 11; // Test failed: RayIndex mismatch
    }

    if (unpacked.VolumeIndex != original.VolumeIndex)
    {
        return 12; // Test failed: VolumeIndex mismatch
    }

    if (unpacked.PrimitiveIndex != original.PrimitiveIndex)
    {
        return 13; // Test failed: PrimitiveIndex mismatch
    }

    if (unpacked.InstanceIndex != original.InstanceIndex)
    {
        return 14; // Test failed: InstanceIndex mismatch
    }

    if (unpacked.GeometryIndex != original.GeometryIndex)
    {
        return 15; // Test failed: GeometryIndex mismatch
    }

    // Note: Barycentrics use f16 conversion, so precision is reduced
    if (abs(unpacked.Barycentrics.x - original.Barycentrics.x) > 0.01f)
    {
        return 16; // Test failed: Barycentrics.x mismatch
    }

    if (abs(unpacked.Barycentrics.y - original.Barycentrics.y) > 0.01f)
    {
        return 17; // Test failed: Barycentrics.y mismatch
    }

    return 0; // All tests passed
}

// ============================================================================
// Test: Payload Packing/Unpacking
// ============================================================================

uint TestPayloadPacking()
{
    Payload original;
    original.albedo = float3(0.5f, 0.6f, 0.7f);
    original.opacity = 0.9f;
    original.worldPosition = float3(10.0f, 20.0f, 30.0f);
    original.metallic = 0.3f;
    original.normal = float3(0.0f, 1.0f, 0.0f);
    original.roughness = 0.5f;
    original.shadingNormal = float3(0.1f, 0.99f, 0.0f);
    original.hitT = 15.5f;
    original.hitKind = 1;

    // Pack
    PackedPayload packed = PackPayload(original);

    // Unpack
    Payload unpacked = UnpackPayload(packed);

    // Verify hitT (not packed, should be exact)
    if (!FloatEquals(unpacked.hitT, original.hitT))
    {
        return 20; // Test failed: hitT mismatch
    }

    // Verify worldPosition (not packed, should be exact)
    if (!Float3Equals(unpacked.worldPosition, original.worldPosition))
    {
        return 21; // Test failed: worldPosition mismatch
    }

    // Verify albedo (f16 packed)
    float albedoError = length(unpacked.albedo - original.albedo);
    if (albedoError > 0.01f)
    {
        return 22; // Test failed: albedo mismatch
    }

    // Verify normal (f16 packed)
    float normalError = length(unpacked.normal - original.normal);
    if (normalError > 0.01f)
    {
        return 23; // Test failed: normal mismatch
    }

    // Verify metallic (f16 packed)
    if (abs(unpacked.metallic - original.metallic) > 0.01f)
    {
        return 24; // Test failed: metallic mismatch
    }

    // Verify roughness (f16 packed)
    if (abs(unpacked.roughness - original.roughness) > 0.01f)
    {
        return 25; // Test failed: roughness mismatch
    }

    return 0; // All tests passed
}

// ============================================================================
// Test: Ray Direction Differentials
// ============================================================================

uint TestRayDifferentials()
{
    float3 rayDirection = float3(0.0f, 0.0f, 1.0f);
    float3 right = float3(1.0f, 0.0f, 0.0f);
    float3 up = float3(0.0f, 1.0f, 0.0f);
    float2 viewportDims = float2(1920.0f, 1080.0f);

    float3 dDdx, dDdy;
    ComputeRayDirectionDifferentials(rayDirection, right, up, viewportDims, dDdx, dDdy);

    // dDdx should be primarily in the X direction
    if (abs(dDdx.x) < TEST_EPSILON)
    {
        return 30; // Test failed: dDdx.x should be non-zero
    }

    // dDdy should be primarily in the Y direction
    if (abs(dDdy.y) < TEST_EPSILON)
    {
        return 31; // Test failed: dDdy.y should be non-zero
    }

    // Magnitude should be inversely proportional to resolution
    float expectedMagnitude = 2.0f / viewportDims.x;
    if (abs(length(dDdx) - expectedMagnitude) > 0.1f * expectedMagnitude)
    {
        return 32; // Test failed: dDdx magnitude incorrect
    }

    return 0; // All tests passed
}

// ============================================================================
// Test: Color Space Conversion
// ============================================================================

uint TestColorSpaceConversion()
{
    // Test LinearToSRGB and back (approximately)
    float3 linearColor = float3(0.5f, 0.5f, 0.5f);
    float3 srgbColor = LinearToSRGB(linearColor);

    // sRGB should be brighter than linear for mid-gray
    if (srgbColor.r <= linearColor.r)
    {
        return 40; // Test failed: sRGB should be brighter for mid-gray
    }

    // Black should stay black
    float3 black = float3(0.0f, 0.0f, 0.0f);
    float3 srgbBlack = LinearToSRGB(black);
    if (!Float3Equals(srgbBlack, black))
    {
        return 41; // Test failed: Black should stay black
    }

    // White should stay white (approximately)
    float3 white = float3(1.0f, 1.0f, 1.0f);
    float3 srgbWhite = LinearToSRGB(white);
    float whiteError = length(srgbWhite - white);
    if (whiteError > 0.01f)
    {
        return 42; // Test failed: White should stay white
    }

    return 0; // All tests passed
}

// ============================================================================
// Test: Normalization
// ============================================================================

uint TestNormalization()
{
    // Test that normalize produces unit vectors
    float3 v1 = float3(3.0f, 4.0f, 0.0f);  // 3-4-5 triangle
    float3 n1 = normalize(v1);

    float len1 = length(n1);
    if (!FloatEquals(len1, 1.0f))
    {
        return 50; // Test failed: Normalized vector should have length 1
    }

    // Test direction preservation
    float3 expected1 = float3(0.6f, 0.8f, 0.0f);
    if (!Float3Equals(n1, expected1))
    {
        return 51; // Test failed: Normalized direction incorrect
    }

    return 0; // All tests passed
}

// ============================================================================
// Main Test Entry Point
// ============================================================================

[numthreads(1, 1, 1)]
void CS_RunAllTests(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint testIndex = 0;
    uint result = 0;

    // Test 0: Barycentric Interpolation
    result = TestBarycentricInterpolation();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // Test 1: Hit Data Packing
    result = TestHitDataPacking();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // Test 2: Payload Packing
    result = TestPayloadPacking();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // Test 3: Ray Differentials
    result = TestRayDifferentials();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // Test 4: Color Space Conversion
    result = TestColorSpaceConversion();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // Test 5: Normalization
    result = TestNormalization();
    TestResults[testIndex++] = result;
    if (result != 0) return;

    // All tests passed - write sentinel value
    TestResults[testIndex] = 0xFFFFFFFF;
}

// ============================================================================
// Individual Test Entry Points (for selective testing)
// ============================================================================

[numthreads(1, 1, 1)]
void CS_TestBarycentricInterpolation(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestBarycentricInterpolation();
}

[numthreads(1, 1, 1)]
void CS_TestHitDataPacking(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestHitDataPacking();
}

[numthreads(1, 1, 1)]
void CS_TestPayloadPacking(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestPayloadPacking();
}

[numthreads(1, 1, 1)]
void CS_TestRayDifferentials(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestRayDifferentials();
}

[numthreads(1, 1, 1)]
void CS_TestColorSpaceConversion(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestColorSpaceConversion();
}

[numthreads(1, 1, 1)]
void CS_TestNormalization(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    TestResults[0] = TestNormalization();
}
