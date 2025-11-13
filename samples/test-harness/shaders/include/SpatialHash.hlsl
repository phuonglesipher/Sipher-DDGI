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
    uint hx = WangHash((uint)g.x);
    uint hy = WangHash((uint)g.y);
    uint hz = WangHash((uint)g.z);

    return hx + hy + hz;
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

uint SpatialHashCascadeIndex(float3 P, float3 CameraPos, float BaseCellSize, uint CellNum, uint CascadeNum, float CascadeDistance)
{
    float CascadeIndex = CalculateCascadeIndex(P, CameraPos, CascadeNum, CascadeDistance);
    float CellSize = CalculateCascadeCellSize(CascadeIndex, BaseCellSize);
    return SpatialHashIndex(P, CellSize, CellNum);
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
