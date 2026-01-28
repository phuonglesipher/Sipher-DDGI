# Radiance Cache Stability - Industry Research

**Research Date:** 2026-01-26
**Purpose:** Learn from AAA games and frameworks how to make radiance cache stable

---

## 1. NVIDIA SHaRC (Spatial Hash Radiance Cache)

**Used in:** Cyberpunk 2077, Indiana Jones and the Great Circle, DOOM: The Dark Ages

### Key Architecture

SHaRC uses a **3-pass pipeline**:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   UPDATE Pass   │ ──▶ │   RESOLVE Pass  │ ──▶ │   QUERY Pass    │
│   (Ray Trace)   │     │   (Compute)     │     │   (Ray Trace)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
  AccumulationBuffer     ResolvedBuffer          Early termination
  (new frame data)       (temporal blend)        using cached data
```

### Temporal Stability Mechanism

**1. Dual Buffer System:**
- `AccumulationBuffer`: Stores per-frame radiance + sample counts
- `ResolvedBuffer`: Cross-frame accumulated radiance (persistent)

**2. Frame-Based Accumulation:**
```cpp
// SharcResolveEntry() parameters:
uint maxAccumulatedFrames;  // Higher = better quality, slower response
uint staleFrameNumMax;      // Frames before eviction
```

**3. Integer Accumulation for Precision:**
```hlsl
// Radiance stored as 32-bit integer per component
// Premultiplied with SHARC_RADIANCE_SCALE
// Sample count uses 18 bits (SHARC_SAMPLE_NUM_BIT_NUM)
```

**4. Stale Element Eviction:**
- Track how many frames since last update
- Evict elements older than `staleFrameNumMax`
- Static camera: ~10-20% occupancy
- Fast movement: higher occupancy, more aggressive eviction

### Hash Collision Handling

SHaRC doesn't explicitly resolve collisions - it recommends:
- Larger buffer size (baseline: 2²² = 4M elements)
- 160 MB video memory for default config
- Higher element count for complex scenes

### Key Parameters

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `sceneScale` | Average voxel size | Scene dependent |
| `logarithmBase` | Level distribution | 2.0 |
| `levelBias` | Near-camera clamping | 0 |
| `maxAccumulatedFrames` | Quality vs responsiveness | 32-64 |
| `staleFrameNumMax` | Cache lifetime | 16-32 |

---

## 2. Unreal Engine 5 Lumen

**Used in:** Fortnite, Senua's Saga, The Matrix Awakens

### Two-Level Cache Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     SCREEN PROBES                            │
│   - High spatial resolution (per-pixel areas)                │
│   - Low directional resolution                               │
│   - Traces rays into World Space Radiance Cache              │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│                WORLD SPACE RADIANCE CACHE                    │
│   - Low spatial resolution (placed on clipmap grids)         │
│   - High directional resolution                              │
│   - Relies on temporal accumulation for stability            │
└──────────────────────────────────────────────────────────────┘
```

### Temporal Stability Techniques

**1. Importance Sampling from Previous Frame:**
```
"Lumen checks in directions that had bright lighting last frame"
- Uses previous frame to guide ray directions
- Equivalent to 4x more rays
- Reduces variance significantly
```

**2. Temporal Accumulation:**
- Screen probes accumulated across frames
- World space probes also use temporal blending
- Probes updated over multiple frames (not all at once)

**3. Budget-Based Update:**
```cpp
// Control how many probes update per frame
r.Lumen.ScreenProbeGather.RadianceCache.NumProbesToTraceBudget
// Higher = more responsive, more expensive
// Too low = lighting pops during fast camera movement
```

**4. Screen Space Filtering:**
- No probe prefiltering
- All filtering runs in screen space
- Reduces probe update frequency while maintaining quality

### Key CVars for Stability

```cpp
r.Lumen.ScreenProbeGather.RadianceCache.ProbeResolution  // Probe quality
r.Lumen.ScreenProbeGather.RadianceCache.NumProbesToTraceBudget  // Update rate
r.Lumen.ScreenProbeGather.TemporalFilterProbes  // Temporal filtering
```

---

## 3. AMD GI-1.0 (Two-Level Radiance Caching)

**Released:** GDC 2023, AMD Capsaicin Framework

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    SCREEN PROBES                             │
│   - 8x8 tiles, one probe per tile                           │
│   - Encodes hemispherical radiance                          │
│   - Upscaled over multiple frames                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              WORLD SPACE IRRADIANCE CACHE                    │
│   - Spherical harmonics per brick                           │
│   - Fed by screen probes                                    │
│   - Persistent across frames                                │
└─────────────────────────────────────────────────────────────┘
```

### Temporal Upscaling Strategy

**The key insight: Probes are populated over multiple frames**

```
Frame 1: ¼ of probes filled
Frame 2: ½ of probes filled
Frame 3: ¾ of probes filled
Frame 4: All probes filled
```

- Reduces per-frame cost
- Trades latency for performance
- Empty tiles interpolate from neighbors

### Sampling and Filtering

**1. Hierarchical Caching:**
- Cache used for both sampling AND filtering
- Every sample contributes to cache
- Cache used to guide future samples

**2. Progressive Filtering:**
- Spatio-temporal filtering
- Resolves noise over time
- Separate diffuse and specular GI outputs

---

## 4. COMMON PATTERNS ACROSS ALL SOLUTIONS

### Pattern 1: Dual Buffer / Double Buffering

All major implementations use some form of read/write separation:

```
Frame N:
  Read:  PreviousFrameCache
  Write: CurrentFrameCache (accumulation)

Frame N+1:
  Resolve: Blend(CurrentFrameCache, PreviousFrameCache)
  Swap buffers
```

### Pattern 2: Frame-Based Accumulation (Not Simple Hysteresis)

**Instead of:**
```hlsl
NewValue = lerp(ComputedValue, OldValue, 0.9);  // Simple hysteresis
```

**They use:**
```hlsl
// Accumulate samples over N frames
AccumulatedRadiance += NewRadiance;
SampleCount++;

// Resolve: compute average
FinalRadiance = AccumulatedRadiance / SampleCount;

// Clamp sample count to prevent over-accumulation
SampleCount = min(SampleCount, MaxAccumulatedFrames);
```

### Pattern 3: Stale Entry Eviction

Track when each cache entry was last updated:

```hlsl
struct CacheEntry {
    float3 Radiance;
    uint   SampleCount;
    uint   LastUpdateFrame;  // Key for staleness
};

// In resolve pass:
uint Age = CurrentFrame - Entry.LastUpdateFrame;
if (Age > StaleFrameThreshold) {
    // Evict or reset entry
    Entry.SampleCount = 0;
}
```

### Pattern 4: Importance Sampling from Cache

Use previous frame's cache to guide ray directions:

```hlsl
// Instead of uniform hemisphere sampling:
float3 Direction = GetRandomDirectionOnHemisphere(Normal, Seed);

// Use importance sampling based on cached radiance:
float3 Direction = ImportanceSampleFromCache(CacheEntry, Normal, Seed);
```

### Pattern 5: Budget-Based Updates

Don't update everything every frame:

```hlsl
// Select subset of entries to update
uint EntriesToUpdate = TotalEntries / UpdateBudget;

// Prioritize entries that:
// 1. Haven't been updated recently
// 2. Have high variance
// 3. Are visible on screen
```

---

## 5. RECOMMENDATIONS FOR SIPHER DDGI

Based on this research, here are specific improvements:

### Immediate Changes

**1. Replace Simple Hysteresis with Sample Accumulation:**

```hlsl
// Current (simple hysteresis):
float3 Blended = lerp(NewRadiance, OldRadiance, 0.95);

// Better (sample accumulation):
struct RadianceCacheEntry {
    float3 AccumulatedRadiance;
    float  SampleCount;
    uint   LastUpdateFrame;
};

// In update:
Entry.AccumulatedRadiance += NewRadiance;
Entry.SampleCount = min(Entry.SampleCount + 1.0, MAX_SAMPLES);
Entry.LastUpdateFrame = FrameNumber;

// In resolve:
float3 FinalRadiance = Entry.AccumulatedRadiance / Entry.SampleCount;
```

**2. Add Stale Entry Detection:**

```hlsl
uint Age = FrameNumber - Entry.LastUpdateFrame;
if (Age > STALE_THRESHOLD) {
    // Reset entry for fresh data
    Entry.AccumulatedRadiance = float3(0, 0, 0);
    Entry.SampleCount = 0;
}
```

**3. Implement Proper Double Buffering:**

```cpp
// CPU side:
ID3D12Resource* RadianceCacheBuffers[2];
uint CurrentBuffer = FrameNumber % 2;
uint PreviousBuffer = 1 - CurrentBuffer;

// Write to CurrentBuffer, read from PreviousBuffer
```

### Medium-Term Changes

**4. Add Variance Tracking:**

```hlsl
struct RadianceCacheEntry {
    float3 AccumulatedRadiance;
    float3 AccumulatedRadianceSq;  // For variance
    float  SampleCount;
    uint   LastUpdateFrame;
};

// Compute variance for adaptive sampling
float3 Mean = AccumulatedRadiance / SampleCount;
float3 Variance = (AccumulatedRadianceSq / SampleCount) - (Mean * Mean);
```

**5. Budget-Based Cache Updates:**

Only update a fraction of cache entries per frame, prioritizing:
- High-variance entries
- Stale entries
- Screen-visible entries

### Long-Term Changes

**6. Two-Level Cache (like Lumen/GI-1.0):**

```
Screen-space probes (high spatial, low directional)
        │
        ▼
World-space cache (low spatial, high directional)
```

**7. Neural Radiance Cache (like NVIDIA NRC):**

Use ML to predict radiance at any point, trained continuously on path-traced data.

---

## 6. idTech8 "FAST AS HELL" (SIGGRAPH 2025)

**Used in:** DOOM: The Dark Ages

### Key Insights from Tiago Sousa's Presentation

**1. SHaRC Integration:**
- idTech8 uses NVIDIA SHaRC for world-space radiance caching
- Similar to Cyberpunk 2077 and Indiana Jones implementations

**2. Hybrid Linear/Exponential Accumulation:**
- Linear accumulation for first N samples (typically 32)
- Exponential blending after reaching sample cap
- Provides fast convergence initially, then temporal stability

**3. Implementation Pattern (from Bevy Solari, similar approach):**
```hlsl
// Trace 4 cosine-distributed rays every frame
// Linearly accumulate up to 32 samples
// After 32, exponentially blend for temporal reactivity

float BlendFactor = 1.0f / min(SampleCount, MAX_SAMPLES);
FinalRadiance = lerp(OldRadiance, NewRadiance, BlendFactor);
```

**4. Cell Lifecycle Management:**
- Life counter decay for stale cells
- PCG hash with checksum for collision detection
- Aggressive eviction of unused cells

### Why This Approach Works

The key insight is that the blend factor `1/N` where N is sample count:
- When N=1: blend = 1.0 (100% new value, fast adaptation)
- When N=10: blend = 0.1 (10% new value, converging)
- When N=32: blend = 0.03125 (3% new value, stable)

This is mathematically equivalent to computing a running average, which converges to the true mean as N increases.

---

## 7. KEY TAKEAWAYS

| Technique | Impact | Complexity |
|-----------|--------|------------|
| Hybrid linear/exponential accumulation | High | Low |
| Sample accumulation vs hysteresis | High | Low |
| Stale entry eviction | High | Low |
| Double buffering | Medium | Medium |
| Variance tracking | Medium | Medium |
| Budget-based updates | Medium | Medium |
| Two-level cache | High | High |
| Neural cache | Very High | Very High |

---

## 8. SOURCES

- [NVIDIA SHaRC GitHub](https://github.com/NVIDIA-RTX/SHARC)
- [NVIDIA RTXGI 2.0](https://github.com/NVIDIA-RTX/RTXGI)
- [Lumen Technical Details - Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/lumen-technical-details-in-unreal-engine)
- [AMD GI-1.0 Paper (arXiv)](https://arxiv.org/abs/2310.19855)
- [GDC 2023 - Two-Level Radiance Caching](https://gpuopen.com/videos/two-level-radiance-caching-gi-gdc-2023/)
- [AMD Capsaicin Framework](https://gpuopen.com/learn/amd-capsaicin-framework-release-gi/)

---

*Generated by Claude Code - Industry Research*
