# Realtime Global Illumination in Enshrouded - Analysis for Sipher-DDGI

## Video Reference
- **Video**: https://www.youtube.com/watch?v=57F1ezwH7Mk
- **Title**: Realtime Global Illumination in Enshrouded
- **Presenter**: Jakub Kolesik (Senior Graphics Programmer, Keen Games)
- **Conference**: Graphics Programming Conference 2024 (November 12, 2024)

---

## 1. Overview of Enshrouded's GI System

Enshrouded is a survival action RPG with a **fully voxel-based, destructible world**. This presents unique challenges for global illumination since **pre-baked lighting is not an option** - everything can be destroyed or built by players.

### Key Requirements
- **Dynamic lighting**: No pre-baked lightmaps possible
- **Wide GPU support**: Must run on various hardware, not just RTX cards
- **Real-time performance**: Smooth gameplay with complex lighting
- **Versatile**: Handle diverse scenarios (sunny outdoors, foggy forests, dark caves)

### Solution: Custom SDF-Based GI

Keen Games developed their own **Signed Distance Field (SDF) ray tracing** system instead of relying on hardware Vulkan/DXR ray tracing. This allows:
- Wider GPU compatibility (works without RT cores)
- Custom optimizations for their voxel engine
- Stochastic sampling for performance

---

## 2. Technical Components

Based on available information, Enshrouded's GI includes:

### 2.1 SDF Ray Tracing
- Custom SDF representation of scene geometry
- Software ray marching instead of hardware RT
- Optimized for their proprietary voxel engine ("Holistic Engine")

### 2.2 Probe-Based Irradiance (Similar to DDGI)
- Uses probe tracing with SDF (similar to Lumen's approach)
- Lower-resolution texture volumes for performance
- Stochastic probe selection (one from every 8-probe cage)

### 2.3 Dynamic Diffuse & Specular GI
- **Diffuse GI**: Probe-based irradiance for soft indirect lighting
- **Specular GI**: Stochastic SDF reflections + Screen Space Reflections
- Handles both "shiny specular armor" and "diffuse foggy forests"

### 2.4 SDF Point Light Shadows
- Soft shadows using SDF ray marching
- Distance Field shadows for intricate silhouettes

### 2.5 Stochastic Sampling
- Noise-based sampling to reduce computation
- Temporal accumulation for stability
- "All rounded up with a bit of stochastic to make everything fast and smooth"

---

## 3. Comparison with Sipher-DDGI

| Feature | Enshrouded | Sipher-DDGI |
|---------|------------|-------------|
| **Ray Tracing** | Custom SDF rays | Hardware RT (DXR/Vulkan) + Inline RT |
| **Probe System** | SDF probe tracing | DDGI irradiance probes |
| **Diffuse GI** | Probe-based | DDGI probes |
| **Specular** | Stochastic SDF + SSR | Not implemented (path tracer reference) |
| **Shadows** | SDF soft shadows | Hardware RT shadows |
| **Scene Repr.** | Voxels + SDF | Triangle meshes + BVH |
| **GPU Support** | Wide (no RT cores needed) | Requires RT-capable GPU |
| **Radiance Cache** | Unknown | Spatial hash + deferred shading |

### Key Differences

1. **Scene Representation**: Enshrouded uses voxels (destructible world), Sipher-DDGI uses traditional triangle meshes

2. **Ray Tracing Approach**: Enshrouded chose SDF for wider compatibility; Sipher-DDGI leverages hardware RT for quality

3. **Specular Handling**: Enshrouded has dedicated stochastic specular system; Sipher-DDGI relies on path tracer for reference

---

## 4. Applicable Techniques for Sipher-DDGI

### 4.1 Stochastic Probe Selection (High Priority)

**What Enshrouded Does**: Select one probe from every 8-probe cage stochastically instead of evaluating all probes.

**Application to Sipher-DDGI**:
```hlsl
// Current: Evaluate all 8 surrounding probes
float3 irradiance = SampleDDGIIrradiance(worldPos, normal, volume);

// Enshrouded-style: Stochastic selection
uint probeIdx = HashPosition(worldPos, frameIndex) % 8;
float3 irradiance = SampleSingleProbe(worldPos, normal, volume, probeIdx) * 8.0;
```

**Benefits**:
- 8x fewer probe texture samples per pixel
- Temporal accumulation smooths noise
- Significant performance improvement

### 4.2 Stochastic Specular Reflections (Medium Priority)

**What Enshrouded Does**: Combines stochastic SDF reflections with Screen Space Reflections.

**Application to Sipher-DDGI**:
```hlsl
// Hybrid specular approach
float3 specular = 0;

// 1. Try screen-space first (cheap, accurate when visible)
float3 ssrResult;
if (TraceScreenSpaceReflection(worldPos, reflectDir, ssrResult)) {
    specular = ssrResult;
} else {
    // 2. Fall back to probe-based or ray-traced
    specular = SampleSpecularFromProbes(worldPos, reflectDir, roughness);
}
```

**Benefits**:
- Efficient specular without full path tracing
- Good quality for smooth surfaces
- Fallback for off-screen reflections

### 4.3 Multi-Resolution Probe Cascades (Medium Priority)

**What Enshrouded Does**: Uses lower-resolution texture volumes, likely with distance-based quality falloff.

**Application to Sipher-DDGI**:
```hlsl
// Distance-based probe resolution
float distToCamera = length(worldPos - cameraPos);
uint cascadeLevel = ComputeCascade(distToCamera);

// Use coarser probes for distant surfaces
DDGIVolume volume = volumes[cascadeLevel];
```

**Benefits**:
- Better performance for large worlds
- Quality where it matters (near camera)
- Already partially implemented in radiance cache cascades

### 4.4 SDF-Based Soft Shadows (Lower Priority for RT Hardware)

**What Enshrouded Does**: Uses SDF for soft shadows with penumbra.

**Note**: Since Sipher-DDGI targets RT-capable hardware, hardware ray traced shadows are likely better quality. However, SDF could be useful for:
- Distant shadow LOD
- Area light approximation
- Performance fallback

---

## 5. Recommended Integration Plan

### Phase 1: Stochastic Probe Sampling

Modify `IndirectCS.hlsl` to use stochastic probe selection:

```hlsl
// In IndirectCS.hlsl
float3 GetStochasticIndirect(float3 worldPos, float3 normal, uint2 pixelCoord)
{
    // Hash for temporal stability
    uint hash = WangHash(pixelCoord.x + pixelCoord.y * screenWidth + frameIndex);

    // Select probe stochastically
    float3 probeGridCoord = GetProbeGridCoords(worldPos, volume);
    uint probeOffset = hash % 8;

    // Sample single probe with weight correction
    float3 irradiance = SampleProbeWithOffset(probeGridCoord, probeOffset, normal);

    return irradiance;
}
```

### Phase 2: Hybrid Specular System

Add `SpecularCS.hlsl` for stochastic specular:

```hlsl
[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
    float3 worldPos = LoadWorldPosition(DTid.xy);
    float3 normal = LoadNormal(DTid.xy);
    float roughness = LoadRoughness(DTid.xy);
    float3 viewDir = normalize(cameraPos - worldPos);

    // Skip rough surfaces (handled by diffuse GI)
    if (roughness > 0.5) {
        SpecularOutput[DTid.xy] = 0;
        return;
    }

    float3 reflectDir = reflect(-viewDir, normal);
    float3 specular = 0;

    // Try SSR first
    if (!TraceSSR(worldPos, reflectDir, specular)) {
        // Stochastic probe-based fallback
        specular = SampleSpecularProbes(worldPos, reflectDir, roughness);
    }

    SpecularOutput[DTid.xy] = float4(specular, 1);
}
```

### Phase 3: Performance Optimization

Apply Enshrouded-style optimizations:

1. **Temporal accumulation** for stochastic sampling
2. **Adaptive quality** based on material properties
3. **Screen-space priority** for common cases

---

## 6. Key Takeaways from Enshrouded's Approach

### What Worked for Them
1. **SDF over Hardware RT**: Enabled wider GPU support
2. **Stochastic Sampling**: Made complex GI real-time feasible
3. **Hybrid Approaches**: Combining multiple techniques for different scenarios
4. **Custom Engine Integration**: Tight coupling with voxel system

### What's Different for Sipher-DDGI
1. **Hardware RT Available**: Can use higher-quality tracing
2. **Triangle Meshes**: Don't need SDF representation
3. **Existing DDGI**: Already have solid probe infrastructure
4. **Radiance Cache**: Advanced caching already in place

### Recommendations
1. **Adopt stochastic probe sampling** - easy win for performance
2. **Add hybrid specular** - improves visual quality significantly
3. **Keep hardware RT** - quality advantage over SDF
4. **Consider SDF for soft shadows** - optional performance/quality tradeoff

---

## 7. References

- [Graphics Programming Conference 2024 Archive](https://graphicsprogrammingconference.com/archive/2024/)
- [Jakub Kolesik LinkedIn](https://www.linkedin.com/in/jakub-kolesik-49083684/)
- [Enshrouded Voxel Engine Overview](https://www.gtxgaming.co.uk/building-new-worlds-exploring-enshroudeds-voxel-based-system/)
- [DDGI Overview (Morgan McGuire)](https://morgan3d.github.io/articles/2019-04-01-ddgi/overview.html)
- [AMD GI-1.0 Screen Space Radiance Caching](https://gpuopen.com/download/publications/GPUOpen2022_GI1_0.pdf)
- [Godot SDFGI Documentation](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/using_sdfgi.html)

---

## 8. Conclusion

Enshrouded's GI system demonstrates that **real-time dynamic global illumination is achievable** even in fully destructible voxel worlds, through clever use of:
- Custom SDF ray tracing for compatibility
- Stochastic sampling for performance
- Hybrid diffuse/specular approaches

For Sipher-DDGI, the most valuable techniques to adopt are:
1. **Stochastic probe sampling** - immediate performance benefit
2. **Hybrid specular system** - improved reflections without full path tracing
3. **Temporal accumulation** - stability for stochastic methods

The key insight is that **stochastic methods with proper temporal filtering** can dramatically reduce computation while maintaining visual quality - a principle that applies regardless of whether you use SDF or hardware ray tracing.
