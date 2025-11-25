#include "../include/Descriptors.hlsl"
#include "../include/Lighting.hlsl"
#include "../include/RayTracing.hlsl"
#include "../include/SpatialHash.hlsl"

#include "../../../../rtxgi-sdk/shaders/ddgi/include/DDGIRootConstants.hlsl"
#include "../../../../rtxgi-sdk/shaders/ddgi/Irradiance.hlsl"

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
    int RayIndex = GroupThreadID.x;                    // index of the ray to trace for this probe
    int ProbeIndex = GroupID.x + GroupID.y * ProbeCount.x + GroupID.z * ProbeCount.x * ProbeCount.y;
    
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
        // The ray hit a surface backface
        if (!RQuery.CandidateTriangleFrontFace())
        {
            // Store the ray backface hit
            DDGIStoreProbeRayBackfaceHit(RayData, outputCoords, volume, RQuery.CommittedRayT());
            return;
        }
    
        // Early out: a "fixed" ray hit a front facing surface. Fixed rays are not blended since their direction
        // is not random and they would bias the irradiance estimate. Don't perform lighting for these rays.
        if((volume.probeRelocationEnabled || volume.probeClassificationEnabled) && RayIndex < RTXGI_DDGI_NUM_FIXED_RAYS)
        {
            // Store the ray front face hit distance (only)
            DDGIStoreProbeRayFrontfaceHit(RayData, outputCoords, volume, RQuery.CommittedRayT());
            return;
        }
    
        RWStructuredBuffer<HitPackedData> HitCachingBuffer = GetHitCachingBuffer();
        float RayDistance = RQuery.CommittedRayT();
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
    }
    else
    {
        // Do miss shading
        DDGIStoreProbeRayMiss(RayData, outputCoords, volume, GetGlobalConst(app, skyRadiance));
    }
}
