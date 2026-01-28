#include "../include/Descriptors.hlsl"
#include "../include/Lighting.hlsl"
#include "../include/RayTracing.hlsl"
#include "../include/SpatialHash.hlsl"

#include "../../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

// Sentinel value for ProbeRayHitMap indicating miss/backface (no cache lookup needed)
#define PROBE_RAY_HIT_MAP_INVALID 0xFFFFFFFF

// Dispatch pattern: (RayGroupsPerProbe, NumProbes, 1)
// where RayGroupsPerProbe = ceil(probeNumRays / 64)
[numthreads(64, 1, 1)]
void CS(uint3 GroupID : SV_GroupID, uint3 GroupThreadID : SV_GroupThreadID, uint ThreadIndexInGroup : SV_GroupIndex)
{
    //Get the DDGIVolume's index (from root/push constants)
    uint VolumeIndex = GetDDGIVolumeIndex();

    // Get the DDGIVolume structured buffers
    StructuredBuffer<DDGIVolumeDescGPUPacked> DDGIVolumes = GetDDGIVolumeConstants(GetDDGIVolumeConstantsIndex());
    StructuredBuffer<DDGIVolumeResourceIndices> DDGIVolumeBindless = GetDDGIVolumeResourceIndices(GetDDGIVolumeResourceIndicesIndex());

    // Get the DDGIVolume's bindless resource indices
    DDGIVolumeResourceIndices ResourceIndices = DDGIVolumeBindless[VolumeIndex];

    // Get the DDGIVolume's constants from the structured buffer
    DDGIVolumeDescGPU volume = UnpackDDGIVolumeDescGPU(DDGIVolumes[VolumeIndex]);

    int3 ProbeCount = volume.probeCounts;

    // New dispatch pattern: GroupID.x = ray group index, GroupID.y = probe linear index
    int ProbeIndex = GroupID.y;
    int RayIndex = GroupID.x * 64 + GroupThreadID.x;

    // Bounds check for ray index (in case probeNumRays is not multiple of 64)
    if (RayIndex >= volume.probeNumRays)
        return;

    // Calculate linear index for ProbeRayHitMap
    uint NumProbes = ProbeCount.x * ProbeCount.y * ProbeCount.z;
    uint ProbeRayIndex = ProbeIndex * volume.probeNumRays + RayIndex;

    // Get the ProbeRayHitMap buffer for storing hash ID and hit distance mapping
    // Format: .x = HashID (or INVALID), .y = asuint(HitDistance)
    RWStructuredBuffer<uint2> ProbeRayHitMapBuffer = GetProbeRayHitMap();

    // Get the probe's grid coordinates
    float3 ProbeCoords = DDGIGetProbeCoords(ProbeIndex, volume);

    // Adjust the probe index for the scroll offsets
    //ProbeIndex = DDGIGetScrollingProbeIndex(ProbeCoords, volume);

    // Get the probe data texture array
    Texture2DArray<float4> ProbeData = GetTex2DArray(ResourceIndices.probeDataSRVIndex);

    // Get the probe's world position
    // Note: world positions are computed from probe coordinates *not* adjusted for infinite scrolling
    float3 probeWorldPosition = DDGIGetProbeWorldPosition(ProbeCoords, volume, ProbeData);

    // Get a random normalized ray direction to use for a probe ray
    float3 probeRayDirection = DDGIGetProbeRayDirection(RayIndex, volume);

    // Get the coordinates for the probe ray in the RayData texture array
    // Note: probe index is the scroll adjusted index (if scrolling is enabled)
    uint3 outputCoords = DDGIGetRayDataTexelCoords(RayIndex, ProbeIndex, volume);

    // Setup the probe ray
    RayDesc ray;
    ray.Origin = probeWorldPosition;
    ray.Direction = probeRayDirection;
    ray.TMin = 0.f;
    ray.TMax = volume.probeMaxRayDistance;

    // Get the acceleration structure
    RaytracingAccelerationStructure SceneTLAS = TLAS[0];

    // Get the ray data texture array
    RWTexture2DArray<float4> RayData = GetRWTex2DArray(ResourceIndices.rayDataUAVIndex);

    RayQuery<RAY_FLAG_NONE> RQuery;
    RQuery.TraceRayInline(SceneTLAS,
            0,
            0xFF,
            ray);
    RQuery.Proceed();
    if(RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        float RayDistance = RQuery.CommittedRayT();

        // The ray hit a surface backface
        // NOTE: Must use CommittedTriangleFrontFace() after Proceed(), not CandidateTriangleFrontFace()
        if (!RQuery.CommittedTriangleFrontFace())
        {
            // Store the ray backface hit - handled directly, no cache needed
            DDGIStoreProbeRayBackfaceHit(RayData, outputCoords, volume, RayDistance);
            ProbeRayHitMapBuffer[ProbeRayIndex] = uint2(PROBE_RAY_HIT_MAP_INVALID, 0);
            return;
        }

        // Early out: a "fixed" ray hit a front facing surface. Fixed rays are not blended since their direction
        // is not random and they would bias the irradiance estimate. Don't perform lighting for these rays.
        if((volume.probeRelocationEnabled || volume.probeClassificationEnabled) && RayIndex < RTXGI_DDGI_NUM_FIXED_RAYS)
        {
            // Store the ray front face hit distance (only) - handled directly, no cache needed
            DDGIStoreProbeRayFrontfaceHit(RayData, outputCoords, volume, RayDistance);
            ProbeRayHitMapBuffer[ProbeRayIndex] = uint2(PROBE_RAY_HIT_MAP_INVALID, 0);
            return;
        }

        RWStructuredBuffer<HitPackedData> HitCachingBuffer = GetHitCachingBuffer();
        float3 HitWorldPosition = probeWorldPosition + probeRayDirection * RayDistance;
        uint HashID = SpatialHashCascadeIndex(HitWorldPosition, GetCascadeCellRadius(), GetMaxCacheCellCount(), GetCascadeCount(), GetCascadeBaseDistance());
        HitUnpackedData NewUnpackedData;
        NewUnpackedData.ProbeIndex = ProbeIndex;
        NewUnpackedData.RayIndex = RayIndex;
        NewUnpackedData.VolumeIndex = VolumeIndex;
        NewUnpackedData.PrimitiveIndex = RQuery.CommittedPrimitiveIndex();
        NewUnpackedData.InstanceIndex = RQuery.CommittedInstanceIndex();
        NewUnpackedData.GeometryIndex = RQuery.CommittedGeometryIndex();
        NewUnpackedData.HitDistance = RayDistance;
        NewUnpackedData.Barycentrics = RQuery.CommittedTriangleBarycentrics();
        HitPackedData NewPackedData;
        PackData(NewUnpackedData, NewPackedData);
        HitCachingBuffer[HashID] = NewPackedData;

        // Store HashID AND HitDistance for resolve pass
        // Each ray needs its own HitDistance (not shared from hash cell)
        ProbeRayHitMapBuffer[ProbeRayIndex] = uint2(HashID, asuint(RayDistance));
    }
    else
    {
        // Do miss shading - handled directly, no cache needed
        DDGIStoreProbeRayMiss(RayData, outputCoords, volume, GetGlobalConst(app, skyRadiance));
        ProbeRayHitMapBuffer[ProbeRayIndex] = uint2(PROBE_RAY_HIT_MAP_INVALID, 0);
    }
}
