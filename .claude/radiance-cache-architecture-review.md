# Review Kiến Trúc Radiance Cache

**Ngày review:** 2026-01-28
**Branch:** feature/stable-radiance-cache
**Revision:** 4424b64

## Tổng Quan

Radiance Cache trong project Sipher-DDGI là một hệ thống **deferred shading** được thiết kế để tăng tốc global illumination (GI) bằng cách cache các giá trị radiance trong một spatial hash grid. Hệ thống này tích hợp với NVIDIA RTXGI SDK và lấy cảm hứng từ kỹ thuật SHaRC (Spatial Hashing and Radiance Caching) của idTech8.

---

## 1. Kiến Trúc Tổng Thể

### Pipeline Flow

```
┌─────────────────────┐
│   ProbeTraceCS      │ Stage 1: Trace rays từ DDGI probes
│   (Ray Tracing)     │ → Hit data được hash vào spatial grid
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  RadianceCacheCS    │ Stage 2: Shading tại mỗi hash cell
│  (Compute Shader)   │ → Direct + Indirect lighting
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│   DDGI Blending     │ Stage 3: Blend vào probe irradiance
│   (SDK Built-in)    │ → Standard RTXGI probe update
└─────────────────────┘
```

### Ưu Điểm Của Thiết Kế 2-Stage

1. **Spatial Coherence**: Nhiều rays hit cùng một vùng → shade 1 lần, reuse nhiều lần
2. **Memory Efficiency**: Lưu radiance theo spatial cell thay vì per-ray
3. **Temporal Reuse**: Cache entry có thể được reuse qua frames
4. **Workload Balance**: Stage 2 dispatch theo số cells thay vì số rays

---

## 2. Spatial Hash System

### Hash Function (SpatialHash.hlsl:20-36)

```hlsl
uint SpatialHash_H(float3 P, float cellSize)
{
    int3 g = GridCoord(P, cellSize);

    // FNV-1a style hash
    uint h = 0x811c9dc5u;  // FNV offset basis
    h ^= (uint)g.x;
    h *= 0x01000193u;      // FNV prime
    h ^= (uint)g.y;
    h *= 0x01000193u;
    h ^= (uint)g.z;
    h *= 0x01000193u;

    return WangHash(h);    // Final mixing
}
```

**Nhận xét:**
- ✅ Sử dụng FNV-1a tránh collision từ permutation (1,2,3) vs (3,2,1)
- ✅ Wang hash cuối cùng để phân phối đều
- ⚠️ Không sử dụng checksum để detect collision (có function nhưng chưa dùng)

### Cascade System

```
┌────────────────────────────────────────────────────────────┐
│                                                            │
│   Cascade 0 (0-20m)    Cell = 0.2m   ●●●●●●●●●●●●●●●●●●   │
│   Cascade 1 (20-40m)   Cell = 0.4m   ○ ○ ○ ○ ○ ○ ○ ○ ○    │
│   Cascade 2 (40-80m)   Cell = 0.8m   ◎   ◎   ◎   ◎   ◎    │
│   ...                                                      │
│                        Camera                              │
└────────────────────────────────────────────────────────────┘
```

**Tính toán:**
- `CellSize = BaseCellSize * 2^CascadeIndex`
- `CascadeIndex = floor(Distance / CascadeDistance)`

**Nhận xét:**
- ✅ LOD phù hợp với mắt người (chi tiết gần, thô xa)
- ✅ Exponential scaling tối ưu memory usage
- ⚠️ Cascade transition có thể gây visual discontinuity

---

## 3. Hit Data Packing

### Structure (Types.h)

```cpp
struct HitPackedData {
    // Packed into 16 bytes total:
    // Word 0: ProbeIndex(16) | RayIndex(8) | VolumeIndex(8)
    // Word 1: InstanceIndex(12) | PrimitiveIndex(10) | GeometryIndex(10)
    // Word 2-3: Barycentrics (2x float16), HitDistance (float32)
};
```

**Nhận xét:**
- ✅ Compact 16 bytes per entry
- ✅ Đủ precision cho geometry lookup
- ⚠️ ProbeIndex 16 bits = max 65536 probes per volume

---

## 4. Temporal Stability (SHaRC-inspired)

### Atomic Accumulation Path (RadianceCacheCS.hlsl:255-297)

```hlsl
// Scale to integers
uint3 ScaledRadiance = uint3(saturate(NewRadiance) * 1024.0f);

// Thread-safe accumulation
AccumulationBuffer.InterlockedAdd(ByteOffset + 0, ScaledRadiance.x);
AccumulationBuffer.InterlockedAdd(ByteOffset + 4, ScaledRadiance.y);
AccumulationBuffer.InterlockedAdd(ByteOffset + 8, ScaledRadiance.z);
AccumulationBuffer.InterlockedAdd(ByteOffset + 12, 1u);

// Average và blend với history
float3 AccumulatedRadiance = float3(R, G, B) / (Scale * SampleCount);
float BlendFactor = 1.0f / min(SampleCount, 32.0f);
FinalRadiance = lerp(OldRadiance, AccumulatedRadiance, BlendFactor);
```

**Analysis:**

| Aspect | Implementation | Đánh Giá |
|--------|---------------|----------|
| Thread Safety | InterlockedAdd on uint | ✅ Race-free |
| Precision | 1024.0 scale factor | ⚠️ Có thể overflow với HDR |
| Temporal Blend | Linear → Exponential | ✅ Giống SHaRC/Bevy Solari |
| Sample Cap | 32 samples | ✅ Balance stability/reactivity |

### Vấn Đề Tiềm Ẩn

1. **HDR Overflow**: `saturate(NewRadiance)` clamp về [0,1], mất HDR info
2. **Race Condition nhẹ**: Đọc `OldRadiance` không atomic với write
3. **Cache Coherence**: Clear toàn bộ mỗi frame → mất temporal history

---

## 5. Indirect Lighting Evaluation

### Hemisphere Sampling (RadianceCacheCS.hlsl:91-149)

```hlsl
for (uint Idx = 0; Idx < SampleCount; Idx++)
{
    // Deterministic seed từ world position
    uint Seed = asuint(WorldPosition.x) ^ asuint(WorldPosition.y) ^ asuint(WorldPosition.z);
    Seed = WangHash(Seed + Idx * 17);
    float3 SamplingDirection = GetRandomDirectionOnHemisphere(WorldNormal, Seed);

    // Inline ray trace
    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> RQuery;
    RQuery.TraceRayInline(BVH, ...);

    // Sample từ radiance cache
    if (hit) {
        InIrradiance = RadianceCachingBuffer[SpatialHash(hitPosition)];
    }
}
```

**Nhận xét:**
- ✅ Deterministic seeding → temporal coherence
- ✅ `ACCEPT_FIRST_HIT_AND_END_SEARCH` tối ưu performance
- ⚠️ 8 samples/point có thể noisy cho high-frequency details
- ⚠️ Recursive cache lookup có thể propagate errors

---

## 6. Đánh Giá Chi Tiết

### Strengths

| Feature | Description |
|---------|-------------|
| **Inline RT** | Sử dụng DXR 1.1 RayQuery thay vì full RT pipeline → giảm overhead |
| **Spatial Hashing** | O(1) lookup, cache-friendly cho GPU |
| **Cascade LOD** | Memory efficient, visual quality scale với distance |
| **Atomic Accumulation** | Thread-safe temporal blending |
| **DDGI Integration** | Seamless với RTXGI SDK probe system |

### Weaknesses & Risks

| Issue | Severity | Description |
|-------|----------|-------------|
| **HDR Loss** | Medium | `saturate()` clamp mất bright values |
| ~~**Hash Collision**~~ | ~~Low~~ | ~~Checksum computed nhưng không được sử dụng~~ **FIXED** - Age-based eviction |
| ~~**Clear Every Frame**~~ | ~~High~~ | ~~`ClearRadianceCache()` xóa history mỗi frame~~ **FIXED** |
| ~~**No Cache Invalidation**~~ | ~~Medium~~ | ~~Stale data khi geometry moves~~ **FIXED** - Age-based eviction handles this |
| **Fixed Sample Count** | Low | 8 samples có thể insufficient |

### Performance Considerations

```
Memory Usage per Cascade:
- Hit Cache:    100,000 × 16 bytes = 1.6 MB
- Radiance:     100,000 × 12 bytes = 1.2 MB
- Accumulation: 100,000 × 16 bytes = 1.6 MB
- Metadata:     100,000 × 8 bytes  = 0.8 MB  (NEW: checksum + frame)
- Visualization: 100,000 × 24 bytes = 2.4 MB
─────────────────────────────────────────────
Total per Cascade: ~7.6 MB
Total 4 Cascades:  ~30 MB
```

---

## 7. So Sánh Với Reference Implementations

### vs. SHaRC (id Software / Doom Eternal)

| Aspect | SHaRC | This Implementation |
|--------|-------|---------------------|
| Hash Function | MurmurHash3 | FNV-1a + Wang |
| Cascade System | Distance-based | Distance-based ✓ |
| Collision Detection | Checksum verification | Not used |
| Temporal Blend | Exponential moving avg | Linear → Exponential ✓ |
| Atomic Ops | uint32 RGB+A | uint32 per channel ✓ |

### vs. Bevy Solari

| Aspect | Bevy Solari | This Implementation |
|--------|-------------|---------------------|
| Max Samples | 32 | 32 ✓ |
| Initial Blend | Direct copy | Direct copy ✓ |
| Variance Tracking | Yes | No |
| Adaptive Sampling | Yes | No |

---

## 8. Đề Xuất Cải Tiến

### Priority 1: Critical Fixes

1. **~~Preserve Temporal History~~** ✅ **FIXED**
   - ~~Không clear radiance buffer mỗi frame~~ ✅ Done
   - ~~Chỉ clear accumulation buffer~~ ✅ Done - `ClearRadianceCacheAccumulation()` per-frame
   - `ResetRadianceCache()` cho init/scene change clears cả hai buffers
   - ⚠️ TODO: Implement cache invalidation cho moving objects

2. **HDR Support**
   - Tăng scale factor hoặc sử dụng float atomics (SM 6.6)
   - Hoặc tone-map trước atomic, inverse sau

### Priority 2: Quality Improvements

3. **~~Use Collision Checksum~~** ✅ **IMPLEMENTED** (2026-01-28)
   - Added `RadianceCacheMetadataBuffer` storing checksum + frame number per cell
   - idTech8/SHaRC-style age-based eviction:
     - If collision detected and entry age >= `RADIANCE_CACHE_COLLISION_EVICT_THRESHOLD` (default: 4 frames) → evict old entry
     - If collision detected and entry is recent → skip update to prevent light bleeding
   - Configuration defines:
     - `RADIANCE_CACHE_USE_COLLISION_DETECTION` (default: 1)
     - `RADIANCE_CACHE_MAX_ENTRY_AGE` (default: 8)
     - `RADIANCE_CACHE_COLLISION_EVICT_THRESHOLD` (default: 4)

4. **Adaptive Sample Count**
   - Variance estimation
   - More samples in high-variance areas

### Priority 3: Optimizations

5. **Cache-Friendly Memory Layout**
   - SoA (Structure of Arrays) thay vì AoS
   - Better coalescing cho GPU memory access

6. **Temporal Reprojection**
   - Reuse previous frame cache với motion vectors
   - Reduce convergence time

---

## 9. Kết Luận

Radiance Cache implementation trong Sipher-DDGI là một thiết kế solid với nhiều điểm mạnh:

- ✅ Modern inline ray tracing approach
- ✅ Well-structured cascade system
- ✅ SHaRC-inspired temporal stability
- ✅ Clean integration với RTXGI SDK

Tuy nhiên có một số vấn đề cần address:

- ✅ ~~Temporal history bị reset mỗi frame~~ **FIXED** - Separated `ClearRadianceCacheAccumulation` (per-frame) và `ResetRadianceCache` (init/scene change)
- ⚠️ HDR precision loss
- ⚠️ Collision checksum không được sử dụng

Overall: **8/10** - Production-ready. Critical temporal history issue đã được fix.

---

## 10. Chi Tiết Phát Hiện Mới (2026-01-28)

### 10.1 Index Mismatch giữa Stage 1 và Stage 2

**Observation quan trọng:**
- **Stage 1** (`ProbeTraceCS.hlsl:102`): Writes to `HitCachingBuffer[HashID]`
- **Stage 2** (`RadianceCacheCS.hlsl:158`): Reads from `HitCachingBuffer[HitIndex]`

```hlsl
// ProbeTraceCS.hlsl:90-102
uint HashID = SpatialHashCascadeIndex(HitWorldPosition, ...);
HitPackedData NewPackedData;
// ... pack data ...
HitCachingBuffer[HashID] = NewPackedData;

// RadianceCacheCS.hlsl:156-161
uint HitIndex = GroupID.x * 64 + ThreadIndexInGroup;  // Linear index!
HitPackedData packedHitData = HitCachingBuffer[HitIndex];
```

**Vấn đề:** `HitIndex` (linear index 0..N) ≠ `HashID` (spatial hash)
- Stage 1 writes vào vị trí spatial hash
- Stage 2 reads linearly, có thể đọc sai data

**Có thể đây là intentional design:**
- Mỗi thread trong Stage 2 xử lý một cell slot
- Nếu slot đó có data (từ spatial hash), nó sẽ process
- Empty slots sẽ được skip bởi early-out check (line 168-171)

**Recommendation:** Verify behavior và document rõ ràng

### 10.2 Visualization Buffer Inconsistency

```hlsl
// RadianceCacheCS.hlsl:329-334
IndirectRadianceCachingBuffer[HitIndex].DirectRadiance = lerp(...);
IndirectRadianceCachingBuffer[HitIndex].IndirectRadiance = lerp(...);

// RadianceCacheCS.hlsl:297
RadianceCachingBuffer[HashID] = FinalRadiance;
```

**Vấn đề:** Visualization buffer dùng `HitIndex`, nhưng radiance dùng `HashID`
- Sẽ gây mismatch khi debug visualization

### 10.3 Execution Flow trong DDGI_D3D12.cpp

```cpp
// Execute() function (line 1565-1634)
RayTraceVolumeCS(...)          // Stage 1: Probe tracing
ClearRadianceCacheAccumulation(...) // Clear accum only
RayTraceRadianceCacheCS(...)   // Stage 2: Radiance compute
UpdateDDGIVolumeProbes(...)    // SDK: Probe blending
RelocateDDGIVolumeProbes(...)  // SDK: Probe relocation
ClassifyDDGIVolumeProbes(...)  // SDK: Probe classification
GatherIndirectLighting(...)     // Screen-space gather
```

**Nhận xét:**
- ✅ Correct ordering của các stages
- ✅ Proper barrier sau mỗi compute pass
- ✅ Accumulation buffer được clear trước Stage 2 (line 1592)

### 10.4 Configuration Parameters

```cpp
// DDGI_D3D12.cpp:1416
d3d.CacheCount = 100000;       // Cells per cascade
d3d.CascadeCellRadius = 0.2f;  // Base cell size
d3d.CascadeDistance = 20.0f;   // Distance per cascade
d3d.RadianceCacheSampleCount = 8;  // Indirect samples
```

---

## Appendix: File References

| File | Purpose |
|------|---------|
| `shaders/ddgi/RadianceCacheCS.hlsl` | Main compute shader |
| `shaders/ddgi/ProbeTraceCS.hlsl` | Stage 1 ray tracing |
| `shaders/include/SpatialHash.hlsl` | Hash functions |
| `shaders/include/RadianceCommon.hlsl` | Shared utilities |
| `src/graphics/DDGI_D3D12.cpp` | C++ host code |
| `include/graphics/Types.h` | Data structures |
