# SHaRC Implementation Notes for Sipher DDGI

## Research Summary

Based on [NVIDIA SHaRC](https://github.com/NVIDIA-RTX/SHARC) documentation and source code analysis.

## SHaRC Architecture

### Three-Buffer System
```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│  Hash Entries       │    │  Accumulation       │    │  Resolved           │
│  (uint2: key+check) │    │  (uint4: RGB+count) │    │  (float4: radiance) │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
        │                          │                          │
        │ Collision detection      │ Atomic writes            │ Final output
        └──────────────────────────┴──────────────────────────┘
```

### Atomic Accumulation Pattern
```hlsl
// SHaRC converts float radiance to scaled integers for atomics
uint3 scaledRadiance = uint3(radiance * weight * RADIANCE_SCALE);

// Conditional atomic adds (skip zero to save bandwidth)
if (scaledRadiance.x != 0) InterlockedAdd(accumBuffer[idx].data.x, scaledRadiance.x);
if (scaledRadiance.y != 0) InterlockedAdd(accumBuffer[idx].data.y, scaledRadiance.y);
if (scaledRadiance.z != 0) InterlockedAdd(accumBuffer[idx].data.z, scaledRadiance.z);
if (sampleCount != 0) InterlockedAdd(accumBuffer[idx].data.w, sampleCount);
```

### Two-Pass Pipeline
1. **Update Pass**: Atomic accumulation into per-frame buffer
2. **Resolve Pass**: Blend accumulated data with history

### Linear Probing for Collisions
When hash collision occurs:
```hlsl
for (uint i = entryIndex + 1; i < entryIndex + PROBE_WINDOW_SIZE; ++i) {
    if (hashEntriesBuffer[i] == hashKey) {
        // Found matching entry from prior frame
        break;
    }
}
```

## Current Sipher DDGI Limitations

1. **Single buffer for read/write**: No separate accumulation buffer
2. **float3 type**: Cannot use InterlockedAdd (needs uint)
3. **No hash key storage**: Cannot detect collisions

## Practical Solution Without C++ Changes

Since adding new buffers requires C++ modifications, we implement a **checksum-based ownership** approach:

### Approach: First-Writer-Wins with Checksum

```hlsl
// Compute hash and checksum
uint hashID = SpatialHash_H(position, cellSize);
uint checksum = SpatialHash_Checksum(position, cellSize);

// Pack checksum into unused bits or use luminance-based detection
// If stored checksum differs significantly, skip update
```

### Alternative: Temporal Jittering

Instead of true atomics, spread updates across frames:
- Only update cells where `(hashID + frameNumber) % N == 0`
- Each cell updated every N frames on average
- Reduces race conditions by 1/N factor

## Full SHaRC Integration (Requires C++ Changes)

To fully implement SHaRC, need to add:

1. **RadianceCacheAccumulation buffer** (uint4 per cell)
2. **RadianceCacheHashEntry buffer** (uint2 per cell)
3. **Separate Update and Resolve compute shaders**
4. **Buffer clear/reset each frame**

### Buffer Declarations (for future)
```hlsl
RWStructuredBuffer<RadianceCacheAccumulation> RadianceAccumulation : register(u5, space4);
RWStructuredBuffer<RadianceCacheHashEntry> RadianceHashEntries : register(u5, space5);
```

## References

- [NVIDIA SHaRC GitHub](https://github.com/NVIDIA-RTX/SHARC)
- [RTXGI 2.0 Documentation](https://github.com/NVIDIA-RTX/RTXGI)
- [Integration Guide](https://github.com/NVIDIA-RTX/SHARC/blob/main/docs/Integration.md)
