#ifndef INLINE_RAY_TRACING_COMMON_HLSL
#define INLINE_RAY_TRACING_COMMON_HLSL

// Include RayTracing.hlsl for common functions (LoadIndices, LoadVertices, InterpolateVertex, etc.)
#include "RayTracing.hlsl"

// ============================================================================
// Helper functions for inline ray tracing (compute shaders)
// ============================================================================

/**
 * Apply instance transforms to geometry using an explicit ObjectToWorld matrix.
 * This version is for compute shaders where ObjectToWorld3x4() intrinsic is not available.
 */
void PrepVerticesForRayDiffsInline(Vertex vertices[3], float3x4 objectToWorld, out float3 edge01, out float3 edge02, out float3 faceNormal)
{
    // Apply instance transforms
    vertices[0].position = mul(objectToWorld, float4(vertices[0].position, 1.f)).xyz;
    vertices[1].position = mul(objectToWorld, float4(vertices[1].position, 1.f)).xyz;
    vertices[2].position = mul(objectToWorld, float4(vertices[2].position, 1.f)).xyz;

    // Find edges and face normal
    edge01 = vertices[1].position - vertices[0].position;
    edge02 = vertices[2].position - vertices[0].position;
    faceNormal = cross(edge01, edge02);
}

/**
 * Get the texture coordinate differentials using ray differentials.
 * This version takes an explicit ObjectToWorld matrix for compute shader use.
 */
void ComputeUV0DifferentialsInline(Vertex vertices[3], float3x4 objectToWorld, float3 rayDirection, float hitT, out float2 dUVdx, out float2 dUVdy)
{
    // Initialize a ray differential
    RayDiff rd = (RayDiff)0;

    // Get ray direction differentials
    ComputeRayDirectionDifferentials(rayDirection, GetCamera().right, GetCamera().up, GetCamera().resolution, rd.dDdx, rd.dDdy);

    // Get the triangle edges and face normal
    float3 edge01, edge02, faceNormal;
    PrepVerticesForRayDiffsInline(vertices, objectToWorld, edge01, edge02, faceNormal);

    // Propagate the ray differential to the current hit point
    PropagateRayDiff(rayDirection, hitT, faceNormal, rd);

    // Get the barycentric differentials
    float2 dBarydx, dBarydy;
    ComputeBarycentricDifferentials(rd, rayDirection, edge01, edge02, faceNormal, dBarydx, dBarydy);

    // Interpolate the texture coordinate differentials
    InterpolateTexCoordDifferentials(dBarydx, dBarydy, vertices, dUVdx, dUVdy);
}

// ============================================================================
// Shade triangle hit functions for RayQuery
// ============================================================================

// Generic shade function that works with the common RayQuery data
void ShadeTriangleHitInternal(
    inout Payload payload,
    float hitT,
    uint InstanceID,
    uint GeometryIndex,
    uint PrimitiveIndex,
    float2 Barycentrics,
    float3x4 ObjectToWorld,
    float3 rayDirection)
{
    payload.hitT = hitT;
    payload.hitKind = 0;

    // Load the intersected mesh geometry's data
    GeometryData geometry;
    GetGeometryData(InstanceID, GeometryIndex, geometry);

    // Load the triangle's vertices
    Vertex vertices[3];
    LoadVertices(InstanceID, PrimitiveIndex, geometry, vertices);

    // Interpolate the triangle's attributes for the hit location
    float3 barycentrics = float3((1.f - Barycentrics.x - Barycentrics.y), Barycentrics.x, Barycentrics.y);
    Vertex v = InterpolateVertex(vertices, barycentrics);

    // World position
    payload.worldPosition = mul(ObjectToWorld, float4(v.position, 1.f)).xyz;

    // Geometric normal
    payload.normal = normalize(mul(ObjectToWorld, float4(v.normal, 0.f)).xyz);
    payload.shadingNormal = payload.normal;

    // Load the surface material
    Material material = GetMaterial(geometry);
    payload.albedo = material.albedo;
    payload.opacity = material.opacity;

    // Compute texture coordinate differentials using inline version (explicit ObjectToWorld matrix)
    float2 dUVdx, dUVdy;
    ComputeUV0DifferentialsInline(vertices, ObjectToWorld, rayDirection, hitT, dUVdx, dUVdy);

    // Albedo and Opacity
    if (material.albedoTexIdx > -1)
    {
        float4 bco = GetTex2D(material.albedoTexIdx).SampleGrad(GetAnisoWrapSampler(), v.uv0, dUVdx, dUVdy);
        payload.albedo *= bco.rgb;
        payload.opacity *= bco.a;
    }

    // Shading normal
    if (material.normalTexIdx > -1)
    {
        float3 tangent = normalize(mul(ObjectToWorld, float4(v.tangent.xyz, 0.f)).xyz);
        float3 bitangent = cross(payload.normal, tangent) * v.tangent.w;
        float3x3 TBN = { tangent, bitangent, payload.normal };

        payload.shadingNormal = GetTex2D(material.normalTexIdx).SampleGrad(GetAnisoWrapSampler(), v.uv0, dUVdx, dUVdy).xyz;
        payload.shadingNormal = (payload.shadingNormal * 2.f) - 1.f;
        payload.shadingNormal = mul(payload.shadingNormal, TBN);
    }

    // Roughness and Metallic
    if (material.roughnessMetallicTexIdx > -1)
    {
        float2 rm = GetTex2D(material.roughnessMetallicTexIdx).SampleGrad(GetAnisoWrapSampler(), v.uv0, dUVdx, dUVdy).gb;
        payload.roughness = rm.x;
        payload.metallic = rm.y;
    }

    // Emissive
    if (material.emissiveTexIdx > -1)
    {
        payload.albedo += GetTex2D(material.emissiveTexIdx).SampleGrad(GetAnisoWrapSampler(), v.uv0, dUVdx, dUVdy).rgb;
    }
}

// Overload for RAY_FLAG_NONE
void ShadeTriangleHit(inout Payload payload, RayQuery<RAY_FLAG_NONE> RQuery)
{
    ShadeTriangleHitInternal(
        payload,
        RQuery.CommittedRayT(),
        RQuery.CommittedInstanceID(),
        RQuery.CommittedGeometryIndex(),
        RQuery.CommittedPrimitiveIndex(),
        RQuery.CommittedTriangleBarycentrics(),
        RQuery.CommittedObjectToWorld3x4(),
        RQuery.WorldRayDirection());
}

// Overload for RAY_FLAG_CULL_BACK_FACING_TRIANGLES
void ShadeTriangleHit(inout Payload payload, RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery)
{
    ShadeTriangleHitInternal(
        payload,
        RQuery.CommittedRayT(),
        RQuery.CommittedInstanceID(),
        RQuery.CommittedGeometryIndex(),
        RQuery.CommittedPrimitiveIndex(),
        RQuery.CommittedTriangleBarycentrics(),
        RQuery.CommittedObjectToWorld3x4(),
        RQuery.WorldRayDirection());
}

#endif // INLINE_RAY_TRACING_COMMON_HLSL
