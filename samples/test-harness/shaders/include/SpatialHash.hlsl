#ifndef SPATIAL_HASH_HLSL
#define SPATIAL_HASH_HLSL

#include "Random.hlsl"

uint XorShift32(uint x)
{
    x ^= (x << 13);
    x ^= (x >> 17);
    x ^= (x << 5);
    return x;
}

int3 GridCoord(float3 P, float cellSize)
{
    float3 q = floor(P / cellSize);
    return (int3)q;
}

uint SpatialHash_H(float3 P, float cellSize)
{
    int3 g = GridCoord(P, cellSize);

    // Better hash combining using PCG-style mixing (idTech8/SHaRC approach)
    // Avoids collisions from simple addition (e.g., (1,2,3) vs (3,2,1))
    uint h = 0x811c9dc5u; // FNV offset basis
    h ^= (uint)g.x;
    h *= 0x01000193u; // FNV prime
    h ^= (uint)g.y;
    h *= 0x01000193u;
    h ^= (uint)g.z;
    h *= 0x01000193u;

    // Final mixing
    return WangHash(h);
}

uint SpatialHash_Checksum(float3 P, float cellSize)
{
    int3 g = GridCoord(P, cellSize);

    uint cx = XorShift32((uint)g.x);
    uint cy = XorShift32((uint)g.y);
    uint cz = XorShift32((uint)g.z);

    return cx + cy + cz;
}

float CalculateCascadeMaxDistance(uint CascadeIdx, float CascadeBaseDistance)
{
    return CascadeBaseDistance * pow(2.0, CascadeIdx);
}

uint CalculateCascadeIndex(float3 P, float3 CameraPos, uint CascadeNum, float CascadeDistance)
{
    float DistToCamera = length(P - CameraPos);
    uint Cascade = min(floor(DistToCamera / CascadeDistance), CascadeNum - 1);
    return Cascade;
}

uint GetCascadeIndex(float3 P, uint CascadeNum, float CascadeDistance)
{
    float3 CameraPos = GetCamera().position;
    return CalculateCascadeIndex(P, CameraPos, CascadeNum, CascadeDistance);;
}

float CalculateCascadeCellSize(float CascadeIndex, float CellSize)
{
    return CellSize * pow(2.0, CascadeIndex);
}

uint SpatialHashIndex(float3 P, float CellSize, uint CellNum)
{
    return SpatialHash_H(P, CellSize) % CellNum;
}

uint SpatialHashCascadeIndex(float3 P, float BaseCellSize, uint CellNum, uint CascadeNum, float CascadeDistance)
{
    float CascadeIndex = GetCascadeIndex(P, CascadeNum, CascadeDistance);
    float CellSize = CalculateCascadeCellSize(CascadeIndex, BaseCellSize);
    return SpatialHashIndex(P, CellSize, CellNum) + CascadeIndex * CellNum;
}

// Get both hash index and checksum for collision detection (SHaRC-style)
void SpatialHashCascadeIndexWithChecksum(
    float3 P,
    float BaseCellSize,
    uint CellNum,
    uint CascadeNum,
    float CascadeDistance,
    out uint HashIndex,
    out uint Checksum)
{
    float CascadeIndex = GetCascadeIndex(P, CascadeNum, CascadeDistance);
    float CellSize = CalculateCascadeCellSize(CascadeIndex, BaseCellSize);
    HashIndex = SpatialHashIndex(P, CellSize, CellNum) + CascadeIndex * CellNum;
    Checksum = SpatialHash_Checksum(P, CellSize);
}

float3 GetSpatialHashVisualColor(uint Hash)
{
    float3 color;
    color.r = ((Hash * 53) % 256) / 255.0f;
    color.g = ((Hash * 127) % 256) / 255.0f;
    color.b = ((Hash * 521) % 256) / 255.0f;
    return color;
}

#endif // SPATIAL_HASH_HLSL
