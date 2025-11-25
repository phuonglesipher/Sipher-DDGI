#ifndef INLINE_RAY_TRACING_COMMON_HLSL
#define INLINE_RAY_TRACING_COMMON_HLSL

uint3 LoadIndices(uint meshIndex, uint primitiveIndex, GeometryData geometry)
{
    uint address = geometry.indexByteAddress + (primitiveIndex * 3) * 4;  // 3 indices per primitive, 4 bytes for each index
    return GetIndexBuffer(meshIndex).Load3(address); // Mesh index buffers start at index 4 and alternate with vertex buffer pointers
}

void LoadVertices(uint meshIndex, uint primitiveIndex, GeometryData geometry, out Vertex vertices[3])
{
    // Get the indices
    uint3 indices = LoadIndices(meshIndex, primitiveIndex, geometry);

    // Load the vertices
    uint address;
    for (uint i = 0; i < 3; i++)
    {
        vertices[i] = (Vertex)0;
        address = geometry.vertexByteAddress + (indices[i] * 12) * 4;  // Vertices contain 12 floats / 48 bytes

        // Load the position
        vertices[i].position = asfloat(GetVertexBuffer(meshIndex).Load3(address));
        address += 12;

        // Load the normal
        vertices[i].normal = asfloat(GetVertexBuffer(meshIndex).Load3(address));
        address += 12;

        // Load the tangent
        vertices[i].tangent = asfloat(GetVertexBuffer(meshIndex).Load4(address));
        address += 16;

        // Load the texture coordinates
        vertices[i].uv0 = asfloat(GetVertexBuffer(meshIndex).Load2(address));
    }
}

Vertex InterpolateVertex(Vertex vertices[3], float3 barycentrics)
{
    // Interpolate the vertex attributes
    Vertex v = (Vertex)0;
    for (uint i = 0; i < 3; i++)
    {
        v.position += vertices[i].position * barycentrics[i];
        v.normal += vertices[i].normal * barycentrics[i];
        v.tangent.xyz += vertices[i].tangent.xyz * barycentrics[i];
        v.uv0 += vertices[i].uv0 * barycentrics[i];
    }

    // Normalize normal and tangent vectors, set tangent direction component
    v.normal = normalize(v.normal);
    v.tangent.xyz = normalize(v.tangent.xyz);
    v.tangent.w = vertices[0].tangent.w;

    return v;
}

struct RayDiff
{
    float3 dOdx;
    float3 dOdy;
    float3 dDdx;
    float3 dDdy;
};

/**
 * Get the ray direction differentials.
 */
void ComputeRayDirectionDifferentials(float3 nonNormalizedCameraRaydir, float3 right, float3 up, float2 viewportDims, out float3 dDdx, out float3 dDdy)
{
    // Igehy Equation 8
    float dd = dot(nonNormalizedCameraRaydir, nonNormalizedCameraRaydir);
    float divd = 2.f / (dd * sqrt(dd));
    float dr = dot(nonNormalizedCameraRaydir, right);
    float du = dot(nonNormalizedCameraRaydir, up);
    dDdx = ((dd * right) - (dr * nonNormalizedCameraRaydir)) * divd / viewportDims.x;
    dDdy = -((dd * up) - (du * nonNormalizedCameraRaydir)) * divd / viewportDims.y;
}

/**
 * Propogate the ray differential to the current hit point.
 */
void PropagateRayDiff(float3 D, float t, float3 N, inout RayDiff rd)
{
    // Part of Igehy Equation 10
    float3 dodx = rd.dOdx + t * rd.dDdx;
    float3 dody = rd.dOdy + t * rd.dDdy;

    // Igehy Equations 10 and 12
    float rcpDN = 1.f / dot(D, N);
    float dtdx = -dot(dodx, N) * rcpDN;
    float dtdy = -dot(dody, N) * rcpDN;
    dodx += D * dtdx;
    dody += D * dtdy;

    // Store differential origins
    rd.dOdx = dodx;
    rd.dOdy = dody;
}

/**
 * Apply instance transforms to geometry, compute triangle edges and normal.
 */
void PrepVerticesForRayDiffs(Vertex vertices[3], float3x4 ObjectToWorld, out float3 edge01, out float3 edge02, out float3 faceNormal)
{
    // Apply instance transforms
    vertices[0].position = mul(ObjectToWorld, float4(vertices[0].position, 1.f)).xyz;
    vertices[1].position = mul(ObjectToWorld, float4(vertices[1].position, 1.f)).xyz;
    vertices[2].position = mul(ObjectToWorld, float4(vertices[2].position, 1.f)).xyz;

    // Find edges and face normal
    edge01 = vertices[1].position - vertices[0].position;
    edge02 = vertices[2].position - vertices[0].position;
    faceNormal = cross(edge01, edge02);
}

/**
 * Get the barycentric differentials.
 */
void ComputeBarycentricDifferentials(RayDiff rd, float3 rayDir, float3 edge01, float3 edge02, float3 faceNormalW, out float2 dBarydx, out float2 dBarydy)
{
    // Igehy "Normal-Interpolated Triangles"
    float3 Nu = cross(edge02, faceNormalW);
    float3 Nv = cross(edge01, faceNormalW);

    // Plane equations for the triangle edges, scaled in order to make the dot with the opposite vertex equal to 1
    float3 Lu = Nu / (dot(Nu, edge01));
    float3 Lv = Nv / (dot(Nv, edge02));

    dBarydx.x = dot(Lu, rd.dOdx);     // du / dx
    dBarydx.y = dot(Lv, rd.dOdx);     // dv / dx
    dBarydy.x = dot(Lu, rd.dOdy);     // du / dy
    dBarydy.y = dot(Lv, rd.dOdy);     // dv / dy
}

/**
 * Get the interpolated texture coordinate differentials.
 */
void InterpolateTexCoordDifferentials(float2 dBarydx, float2 dBarydy, Vertex vertices[3], out float2 dx, out float2 dy)
{
    float2 delta1 = vertices[1].uv0 - vertices[0].uv0;
    float2 delta2 = vertices[2].uv0 - vertices[0].uv0;
    dx = dBarydx.x * delta1 + dBarydx.y * delta2;
    dy = dBarydy.x * delta1 + dBarydy.y * delta2;
}

/**
 * Get the texture coordinate differentials using ray differentials.
 */
//void ComputeUV0Differentials(Vertex vertices[3], ConstantBuffer<Camera> camera, float3 rayDirection, float hitT, out float2 dUVdx, out float2 dUVdy)
void ComputeUV0Differentials(Vertex vertices[3], float3x4 ObjectToWorld, float3 rayDirection, float hitT, out float2 dUVdx, out float2 dUVdy)
{
    // Initialize a ray differential
    RayDiff rd = (RayDiff)0;

    // Get ray direction differentials
    //ComputeRayDirectionDifferentials(rayDirection, camera.right, camera.up, camera.resolution, rd.dDdx, rd.dDdy);
    ComputeRayDirectionDifferentials(rayDirection, GetCamera().right, GetCamera().up, GetCamera().resolution, rd.dDdx, rd.dDdy);

    // Get the triangle edges and face normal
    float3 edge01, edge02, faceNormal;
    PrepVerticesForRayDiffs(vertices, ObjectToWorld, edge01, edge02, faceNormal);

    // Propagate the ray differential to the current hit point
    PropagateRayDiff(rayDirection, hitT, faceNormal, rd);

    // Get the barycentric differentials
    float2 dBarydx, dBarydy;
    ComputeBarycentricDifferentials(rd, rayDirection, edge01, edge02, faceNormal, dBarydx, dBarydy);

    // Interpolate the texture coordinate differentials
    InterpolateTexCoordDifferentials(dBarydx, dBarydy, vertices, dUVdx, dUVdy);
}

void ShadeTriangleHit(inout Payload payload, RayQuery<RAY_FLAG_NONE> RQuery)
{
    payload.hitT = RQuery.CommittedRayT();
    payload.hitKind = 0;

    uint InstanceID = RQuery.CommittedInstanceID();
    uint GeometryIndex = RQuery.CommittedGeometryIndex();
    uint PrimitiveIndex = RQuery.CommittedPrimitiveIndex();

    // Load the intersected mesh geometry's data
    GeometryData geometry;
    GetGeometryData(InstanceID, GeometryIndex, geometry);

    // Load the triangle's vertices
    Vertex vertices[3];
    LoadVertices(InstanceID, PrimitiveIndex, geometry, vertices);

    // Interpolate the triangle's attributes for the hit location (position, normal, tangent, texture coordinates)
    float2 Barycentrics = RQuery.CommittedTriangleBarycentrics();
    float3 barycentrics = float3((1.f - Barycentrics.x - Barycentrics.y), Barycentrics.x, Barycentrics.y);
    Vertex v = InterpolateVertex(vertices, barycentrics);

    // World position
    payload.worldPosition = v.position;
    payload.worldPosition = mul(RQuery.CommittedObjectToWorld3x4(), float4(payload.worldPosition, 1.f)).xyz; // instance transform

    // Geometric normal
    payload.normal = v.normal;
    payload.normal = normalize(mul(RQuery.CommittedObjectToWorld3x4(), float4(payload.normal, 0.f)).xyz);
    payload.shadingNormal = payload.normal;

    // Load the surface material
    Material material = GetMaterial(geometry);
    payload.albedo = material.albedo;
    payload.opacity = material.opacity;

    // Compute texture coordinate differentials
    float2 dUVdx, dUVdy;
    ComputeUV0Differentials(vertices, RQuery.CommittedObjectToWorld3x4(), RQuery.WorldRayDirection(), RQuery.CommittedRayT(), dUVdx, dUVdy);

    // TODO-ACM: passing ConstantBuffer<T> to functions crashes DXC HLSL->SPIRV
    //ConstantBuffer<Camera> camera = GetCamera();
    //ComputeUV0Differentials(vertices, camera, WorldRayDirection(), RayTCurrent(), dUVdx, dUVdy);

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
        float3 tangent = normalize(mul(ObjectToWorld3x4(), float4(v.tangent.xyz, 0.f)).xyz);
        float3 bitangent = cross(payload.normal, tangent) * v.tangent.w;
        float3x3 TBN = { tangent, bitangent, payload.normal };

        payload.shadingNormal = GetTex2D(material.normalTexIdx).SampleGrad(GetAnisoWrapSampler(), v.uv0, dUVdx, dUVdy).xyz;
        payload.shadingNormal = (payload.shadingNormal * 2.f) - 1.f;    // Transform to [-1, 1]
        payload.shadingNormal = mul(payload.shadingNormal, TBN);        // Transform tangent-space normal to world-space
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

#endif // INLINE_RAY_TRACING_COMMON_HLSL
