# Radiance Cache Architecture Review

**Review Date:** 2026-01-26
**Branch:** feature/stable-radiance-cache

---

## 1. FILE OVERVIEW

### Shader Files
| File | Lines | Purpose |
|------|-------|---------|
| `shaders/ddgi/RadianceCacheCS.hlsl` | 201 | Current inline ray tracing compute shader |
| `shaders/ddgi/RadianceCacheRGS.hlsl` | 134 | Legacy ray generation shader (traditional RTX) |
| `shaders/include/RadianceCommon.hlsl` | - | Shared radiance evaluation functions |
| `shaders/include/SpatialHash.hlsl` | - | Spatial hashing implementation |
| `shaders/include/InlineLighting.hlsl` | - | Inline visibility functions |

### C++ Files
| File | Purpose |
|------|---------|
| `include/graphics/DDGI_D3D12.h` | Resource definitions |
| `src/graphics/DDGI_D3D12.cpp` | Implementation and dispatch |
| `include/graphics/Types.h` | Data structures |

---

## 2. DATA STRUCTURES

### HitPackedData (GPU)
```cpp
struct HitPackedData {
    uint ProbePacked;       // 16 bits Probe index, 8 bits ray index, 8 bits volume index
    uint PrimitivePacked;   // 12 bits Instance index, 10 bits primitive index, 10 bits geometry index
    uint Barycentrics;      // 16 bits barycentric U, 16 bits barycentric V
    float HitDistance;
};
```

### HitUnpackedData
```cpp
struct HitUnpackedData {
    uint ProbeIndex, RayIndex, VolumeIndex;
    uint PrimitiveIndex, InstanceIndex, GeometryIndex;
    float2 Barycentrics;
    float HitDistance;
};
```

### RadianceCacheVisualization
```cpp
struct RadianceCacheVisualization {
    float3 DirectRadiance;
    float3 IndirectRadiance;
};
```

### GPU Buffers
```cpp
ID3D12Resource* HitCachingResource;              // RWStructuredBuffer<HitPackedData>
ID3D12Resource* RadianceCachingResource;         // RWStructuredBuffer<float3>
ID3D12Resource* RadianceCachingVisualizationResource; // RWStructuredBuffer<RadianceCacheVisualization>
```

---

## 3. TWO-STAGE PIPELINE

### Stage 1: Probe Ray Tracing (ProbeTraceCS.hlsl)

```
┌─────────────────────────────────────┐
│   For each DDGI probe ray:          │
│   1. Trace ray (inline RayQuery)    │
│   2. On hit: compute spatial hash   │
│   3. Store hit data to cache        │
└─────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│   HitCachingBuffer[HashID]          │
│   - Geometry indices                │
│   - Barycentric coordinates         │
│   - Hit distance                    │
│   - Probe/ray/volume indices        │
└─────────────────────────────────────┘
```

### Stage 2: Radiance Cache Shading (RadianceCacheCS.hlsl)

```
┌─────────────────────────────────────┐
│   For each cached hit:              │
│   1. Load geometry data             │
│   2. Interpolate vertex attributes  │
│   3. Compute DIRECT lighting        │
│      (inline visibility tests)      │
│   4. Compute INDIRECT lighting      │
│      - 8 hemisphere samples         │
│      - Query radiance from cache    │
│      - Lambertian BRDF integral     │
│   5. Store results                  │
└─────────────────────────────────────┘
         │
         ├─→ RadianceCachingBuffer[float3]
         ├─→ RadianceCachingVisualizationBuffer
         └─→ DDGI RayData Texture
```

---

## 4. SPATIAL HASHING

### Hash Function (SpatialHash.hlsl)

```hlsl
uint SpatialHash_H(float3 P, float cellSize)
{
    int3 g = GridCoord(P, cellSize);        // Quantize position to grid
    uint hx = WangHash((uint)g.x);
    uint hy = WangHash((uint)g.y);
    uint hz = WangHash((uint)g.z);
    return hx + hy + hz;                    // Combine hashes
}

uint SpatialHashIndex(float3 P, float CellSize, uint CellNum)
{
    return SpatialHash_H(P, CellSize) % CellNum;
}
```

### Cascade System

```hlsl
uint SpatialHashCascadeIndex(float3 P, float BaseCellSize, uint CellNum,
                             uint CascadeNum, float CascadeDistance)
{
    float CascadeIndex = GetCascadeIndex(P, CascadeNum, CascadeDistance);
    float CellSize = CalculateCascadeCellSize(CascadeIndex, BaseCellSize);
    return SpatialHashIndex(P, CellSize, CellNum) + CascadeIndex * CellNum;
}
```

### Key Features
- **Wang hash** for pseudo-random distribution
- **Camera-distance based** cascade selection
- **Exponential cell size** scaling per cascade
- **Smooth fallback** for distant objects
- **Spatial locality** preservation for cache coherence

---

## 5. MEMORY LAYOUT

### Hit Cache Buffer
| Property | Value |
|----------|-------|
| Type | `RWStructuredBuffer<HitPackedData>` |
| Size | `16 bytes * CacheCount * NumVolumes` |
| Stride | 16 bytes per entry |

### Radiance Cache Buffer
| Property | Value |
|----------|-------|
| Type | `RWStructuredBuffer<float3>` |
| Size | `12 bytes * CacheCount * NumVolumes` |
| Stride | 12 bytes per entry |
| Content | RGB radiance (HDR) |

### Visualization Buffer
| Property | Value |
|----------|-------|
| Type | `RWStructuredBuffer<RadianceCacheVisualization>` |
| Size | `24 bytes * CacheCount * NumVolumes` |
| Stride | 24 bytes (2x float3) |

### Configuration Parameters
```cpp
UINT CacheCount = 100000;              // Max spatial hash cells per cascade
float CascadeCellRadius = 0.2f;        // Base cell size in world units
float CascadeDistance = 20.0f;         // Distance between cascade levels
float RadianceCacheSampleCount = 16.0f; // Indirect samples
```

---

## 6. INLINE RAY TRACING CONVERSION (Commit 18b290b)

### Before vs After

| Aspect | Before (RTX Pipeline) | After (Inline/Compute) |
|--------|----------------------|----------------------|
| Entry Point | Ray Generation Shader | Compute Shader |
| Dispatch | `DispatchRays()` with shader table | `Dispatch((CacheCount+63)/64, 1, 1)` |
| Ray Tracing API | Traditional `TraceRay()` | `RayQuery` (inline) |
| PSO Type | `ID3D12StateObject` (RTPSO) | `ID3D12PipelineState` (Compute) |
| Shader Table | Required (~200 lines) | Not needed |
| Hit Processing | Closest hit shader | Inline payload unpacking |
| Visibility | `TraceRay()` with CHS | `RayQuery` with `ACCEPT_FIRST_HIT` |
| Lines Removed | 239 lines | 45 lines remain |

### Code Simplification
```cpp
// Before: Complex shader table setup (~100+ lines)
// After: Simple compute dispatch
UINT numGroups = (resources.CascadeCellNum + 63) / 64;
d3d.cmdList[d3d.frameIndex]->Dispatch(numGroups, 1, 1);
```

---

## 7. SHADER COMPARISON

### RadianceCacheCS.hlsl vs RadianceCacheRGS.hlsl

| Feature | CS (Current) | RGS (Legacy) |
|---------|--------------|--------------|
| Entry Point | `[numthreads(64,1,1)] void CS()` | `[shader("raygeneration")] void RayGen()` |
| Index | `GroupID.x * 64 + ThreadIndex` | `DispatchRaysIndex().x` |
| Direct Lighting | `DirectDiffuseLightingInline()` | `DirectDiffuseLighting()` |
| Includes | InlineLighting.hlsl | Lighting.hlsl |
| Ray Tracing | `RayQuery` (inline) | `TraceRay()` (traditional) |
| Line Count | 201 | 134 |

### Functional Equivalence
Both shaders:
1. Unpack hit data from spatial hash indexed buffer
2. Load geometry and interpolate vertex attributes
3. Evaluate direct lighting with visibility
4. Evaluate indirect lighting (8 samples)
5. Store results to radiance/visualization buffers
6. Write to DDGI ray data texture

---

## 8. INDIRECT RADIANCE EVALUATION

```hlsl
// 8 hemisphere samples per shading point
for (uint Idx = 0; Idx < RADIANCE_CACHE_SAMPLE_COUNT; Idx++)
{
    float3 SamplingDirection = GetRandomDirectionOnHemisphere(WorldNormal, Seed);

    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> RQuery;
    RQuery.TraceRayInline(BVH, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xFF, ray);
    RQuery.Proceed();

    if (RQuery.CommittedStatus() != COMMITTED_TRIANGLE_HIT)
    {
        // Miss - use sky radiance
        InIrradiance = GetGlobalConst(app, skyRadiance);
    }
    else
    {
        // Hit - query radiance from cache
        float3 hitPosition = WorldPosition + ray.Direction * RQuery.CommittedRayT();
        uint HashID = SpatialHashCascadeIndex(hitPosition, ...);
        InIrradiance = RadianceCachingBuffer[HashID];
    }

    // Lambertian BRDF: L/π * E * cos(θ) / pdf
    IndirectLight += (BRDF * InIrradiance * CosN) / Pdf;
}
IndirectLight /= SampleCount;
```

---

## 9. ARCHITECTURE DIAGRAM

```
┌─────────────────────────────────────┐
│   DDGI Probe Ray Tracing            │
│   (ProbeTraceCS.hlsl)               │
└────────────┬────────────────────────┘
             │ Ray hits (inline RayQuery)
             ▼
    ┌────────────────────┐
    │ Spatial Hash       │
    │ (SpatialHash.hlsl) │ ← Cascade system based on camera distance
    └────────┬───────────┘
             │ HashID = hash(hitPosition)
             ▼
    ┌────────────────────────┐
    │ HitCachingBuffer       │
    │ [HitPackedData]        │ ← Indexed by HashID
    └────────┬───────────────┘
             │
             ▼
    ┌────────────────────────────────────┐
    │  Radiance Cache Shading            │
    │  (RadianceCacheCS.hlsl - CURRENT)  │
    │  (RadianceCacheRGS.hlsl - LEGACY)  │
    │                                    │
    │  1. Unpack hit data               │
    │  2. Load geometry & interpolate   │
    │  3. Evaluate direct lighting      │
    │     (inline visibility)            │
    │  4. Evaluate indirect lighting    │
    │     (8 hemisphere samples)         │
    │  5. Store radiance results        │
    └────────┬───────────────────────────┘
             │
             ├─→ RadianceCachingBuffer[float3]
             ├─→ RadianceCachingVisualizationBuffer
             └─→ DDGI RayData Texture (integration)
                    │
                    ▼
              ┌─────────────────┐
              │ DDGI Processing │
              │ - Blending      │
              │ - Classification│
              │ - Relocation    │
              └────────┬────────┘
                       │
                       ▼
              Final Indirect Lighting
```

---

## 10. DDGI INTEGRATION

### Resource Bindings (Descriptors.hlsl)
```hlsl
RWStructuredBuffer<HitPackedData> HitCaching : register(u5, space1);
RWStructuredBuffer<float3> RadianceCaching : register(u5, space2);
RWStructuredBuffer<RadianceCacheVisualization> RadianceCachingVisualization : register(u5, space3);
```

### DDGI Volume Feedback
1. **ProbeTraceCS** stores hit data indexed by spatial hash
2. **RadianceCacheCS** reads hits, evaluates radiance
3. Result feeds back via `DDGIStoreProbeRayFrontfaceHit()`
4. DDGI processes normally (blending, classification, relocation)

---

## 11. VISUALIZATION (Composite.hlsl)

```hlsl
uint HashID = SpatialHashCascadeIndex(WorldPos, ...);
float3 DirectRadiance = RadianceCacheVisualizationBuffer[HashID].DirectRadiance;
float3 IndirectRadiance = RadianceCacheVisualizationBuffer[HashID].IndirectRadiance;

if (showFlags & COMPOSITE_FLAG_SHOW_DDGI_DIRECT_RADIANCE_CACHE)
    color = DirectRadiance;
if (showFlags & COMPOSITE_FLAG_SHOW_DDGI_INDIRECT_RADIANCE_CACHE)
    color = IndirectRadiance;
```

---

## 12. KEY BENEFITS OF RADIANCE CACHE

1. **Deferred Shading** - Expensive lighting computed once per spatial cell, not per ray
2. **Temporal Stability** - Cache provides consistent results across frames
3. **Scalable Quality** - Adjust cache resolution and sample count
4. **Visualization** - Separate direct/indirect for debugging
5. **DDGI Integration** - Seamless feedback to probe system

---

## 13. POTENTIAL IMPROVEMENTS

1. **Temporal Reprojection** - Reuse cache entries from previous frames
2. **Adaptive Sampling** - More samples in high-variance areas
3. **Cache Invalidation** - Detect and clear stale entries
4. **Compression** - Reduce memory with spherical harmonics
5. **Multi-resolution** - Finer resolution near camera

---

*Generated by Claude Code Architecture Review*
