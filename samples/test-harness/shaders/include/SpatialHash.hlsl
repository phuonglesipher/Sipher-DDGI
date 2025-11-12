#ifndef SPATIAL_HASH_HLSL
#define SPATIAL_HASH_HLSL

#include "Random.hlsl"

#define SPATIAL_HASH_VOXEL_SIZE 0.2
#define SPATIAL_HASH_CASCADE_NUM 2
#define SPATIAL_HASH_CASCADE_LENGTH 20
#define SPATIAL_HASH_CASCADE_CELL_NUM 100000

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

float CalculateCascadeIndex(float3 P, float3 CameraPos)
{
    float DistToCamera = length(P - CameraPos);
    float Cascade = min(floor(DistToCamera / SPATIAL_HASH_CASCADE_LENGTH), SPATIAL_HASH_CASCADE_NUM - 1);
    return Cascade;
}

int GetCascadeIndex(float3 P)
{
    float3 CameraPos = GetCamera().position;
    CameraPos.y = P.y;
    float Cascade = CalculateCascadeIndex(P, CameraPos);
    return Cascade;
}

float CalculateCascadeCellSize(float CascadeIndex)
{
    return SPATIAL_HASH_VOXEL_SIZE * pow(2.0, CascadeIndex);
}

uint SpatialHashIndex(float3 P, float cellSize)
{
    return SpatialHash_H(P, cellSize) % SPATIAL_HASH_CASCADE_CELL_NUM;
}

uint SpatialHashCascadeIndex(float3 P, float3 CameraPos)
{
    float CascadeIndex = CalculateCascadeIndex(P, CameraPos);
    float CellSize = CalculateCascadeCellSize(CascadeIndex);
    return SpatialHashIndex(P, CellSize);
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
