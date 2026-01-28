# SIPHER DDGI - Architecture Review

**Review Date:** 2026-01-26
**Branch:** feature/stable-radiance-cache
**SDK Version:** 1.3.7 (NVIDIA RTX Global Illumination)

---

## 1. PROJECT STRUCTURE OVERVIEW

```
D:/Sipher-DDGI/
├── rtxgi-sdk/              # Core DDGI SDK (C++ + HLSL)
├── samples/test-harness/   # Reference implementation
├── thirdparty/             # Dependencies (GLFW, ImGui, TinyGLTF, Vulkan-Headers, NVAPI)
├── external/               # Runtime dependencies (Agility SDK, DXC)
├── docs/                   # Documentation
├── ue4-plugin/             # Unreal Engine 4 plugin
└── CMakeLists.txt          # Root CMake configuration
```

**Technical Specifications:**
- Build System: CMake 3.10+
- Language: C++17
- Platforms: Windows (D3D12), Linux (Vulkan)
- GPU: DXR or Vulkan Ray Tracing capable GPUs

---

## 2. CORE SDK ARCHITECTURE

### 2.1 rtxgi-sdk/ Structure

```
rtxgi-sdk/
├── include/rtxgi/
│   ├── Common.h              # Version info, error codes
│   ├── Math.h                # Math utilities
│   ├── Types.h               # Vector types, AABB, OBB
│   └── ddgi/
│       ├── DDGIVolume.h      # Main public API
│       ├── DDGIVolumeDescGPU.h # GPU descriptors
│       └── gfx/
│           ├── DDGIVolume_D3D12.h
│           └── DDGIVolume_VK.h
│
├── src/ddgi/
│   ├── DDGIVolume.cpp        # Core cross-platform logic
│   └── gfx/
│       ├── DDGIVolume_D3D12.cpp
│       └── DDGIVolume_VK.cpp
│
└── shaders/ddgi/
    ├── ProbeBlendingCS.hlsl
    ├── ProbeClassificationCS.hlsl
    ├── ProbeRelocationCS.hlsl
    ├── ReductionCS.hlsl
    └── Irradiance.hlsl
```

### 2.2 Core Data Structures

**DDGIVolumeDesc (CPU):**
```cpp
struct DDGIVolumeDesc {
    float3 origin;                  // Volume center
    float3 probeSpacing;            // Spacing between probes
    int3 probeCounts;               // Probes per axis
    int probeNumRays;               // Rays per probe (default 256)
    float probeHysteresis;          // Temporal blending (0.97)
    bool probeRelocationEnabled;    // Move probes to avoid geometry
    bool probeClassificationEnabled;// Disable invalid probes
    // ...
};
```

**DDGIVolumeDescGPUPacked (GPU - 128 bytes):**
- origin, rotation, spacing
- Packed probe counts and settings
- Feature flags

---

## 3. DDGI ALGORITHM

### 3.1 Core Principles

DDGI is a real-time Global Illumination algorithm based on **irradiance probes**:

1. **Probe Grid:** 3D grid of probes caching irradiance
2. **Dynamic Updates:** Each frame traces rays from probes
3. **Visibility Testing:** Statistical occlusion using distance data
4. **Probe Relocation:** Move probes to avoid geometry
5. **Probe Classification:** Disable useless probes

### 3.2 GPU Texture Resources

| Texture | Format | Purpose |
|---------|--------|---------|
| Ray Data | U32x2/F32x4 | Radiance + hit distance |
| Irradiance | U32/F16x4 | Cached irradiance (octahedral) |
| Distance | F16x2/F16x4 | Mean + variance for occlusion |
| Probe Data | F16x4 | Relocation offsets + state |
| Variability | F16/F32 | Convergence tracking |

---

## 4. RENDERING PIPELINE

```
Per-Frame Execution Order:

1. UPDATE PHASE
   └─ CPU update → GPU upload constants

2. G-BUFFER GENERATION
   └─ Ray gen shader OR compute shader

3. PROBE RAY TRACING
   ├─ Dispatch: [numRays, probeCountX, probeCountY, probeCountZ]
   ├─ DXR DispatchRays OR inline RayQuery
   └─ Output: Ray Data texture

4. PROBE BLENDING
   ├─ ProbeBlendingCS.hlsl
   ├─ Hysteresis blending
   └─ Output: Updated Irradiance & Distance

5. PROBE RELOCATION (Optional)
   └─ ProbeRelocationCS.hlsl

6. PROBE CLASSIFICATION (Optional)
   └─ ProbeClassificationCS.hlsl

7. VARIABILITY CALCULATION (Optional)
   └─ ReductionCS.hlsl

8. SCREEN-SPACE INDIRECT
   ├─ Query probes at each pixel
   └─ Output: Indirect lighting buffer

9. FINAL COMPOSITION
```

---

## 5. INLINE RAY TRACING IMPLEMENTATION

### 5.1 Recent Changes (Commit 18b290b)

**Converted from:**
```cpp
// Traditional DXR
DispatchRays() → RadianceCacheRGS.hlsl
Shader table management (~200 lines)
```

**To:**
```cpp
// Inline ray tracing
Dispatch() → RadianceCacheCS.hlsl
RayQuery<> in compute shader
No shader table overhead
```

### 5.2 RayQuery Pattern

```hlsl
RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> RQuery;
RQuery.TraceRayInline(accelerationStructure, flags, mask, ray);

while (RQuery.Proceed()) {
    if (RQuery.CandidateType() == CANDIDATE_TRIANGLE_HIT) {
        // Process candidate
    }
}

if (RQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
    float3 hitPos = origin + dir * RQuery.CommittedRayT();
}
```

### 5.3 Benefits

- **Simpler Code:** No shader table management
- **Better Performance:** Fewer GPU state changes
- **More Flexible:** Interleave compute and ray tracing
- **Easier Debugging:** Single shader to debug

---

## 6. TEST HARNESS ARCHITECTURE

### 6.1 Module Structure

```
samples/test-harness/
├── include/graphics/
│   ├── DDGI.h              # Cross-platform interface
│   ├── DDGI_D3D12.h        # D3D12 specific
│   ├── DDGI_VK.h           # Vulkan specific
│   ├── GBuffer.h           # G-Buffer rendering
│   ├── RTAO.h              # Ray-Traced AO
│   ├── PathTracing.h       # Reference path tracer
│   └── Composite.h         # Final composite
│
├── src/graphics/
│   ├── DDGI.cpp            # ~500 lines
│   ├── DDGI_D3D12.cpp      # ~1000 lines
│   ├── DDGI_VK.cpp         # ~1300 lines
│   └── ...
│
└── shaders/
    ├── ddgi/
    │   ├── ProbeTraceRGS.hlsl   # Traditional DXR
    │   ├── ProbeTraceCS.hlsl    # Inline ray tracing
    │   ├── RadianceCacheCS.hlsl # Inline radiance cache
    │   └── visualizations/
    └── include/
        ├── InlineRayTracingCommon.hlsl
        ├── InlineLighting.hlsl
        ├── RadianceCommon.hlsl
        └── SpatialHash.hlsl
```

### 6.2 Resource Management Modes

1. **Managed Mode:** SDK allocates/owns resources
2. **Unmanaged Mode:** Application allocates, SDK dispatches

---

## 7. MEMORY FOOTPRINT

### 7.1 Per Volume (8×8×8 probes)

```
Irradiance:  64 × 64 × 8 × 4B  = 131 KB
Distance:    48 × 48 × 8 × 4B  =  74 KB
Ray Data:    256 × 512 × 4B    = 512 KB
Probe Data:  64 × 64 × 8 × 4B  = 131 KB
Variability: 64 × 64 × 8 × 2B  =  65 KB
───────────────────────────────────────
Total: ~913 KB
```

### 7.2 Large Volume (32×32×32 probes)

Total: ~50+ MB

---

## 8. FEATURE MATRIX

| Feature | Status | Description |
|---------|--------|-------------|
| Probe Relocation | Optional | Move probes to avoid geometry |
| Probe Classification | Optional | Disable inside-geometry probes |
| Probe Variability | Optional | Track convergence |
| Infinite Scrolling | Optional | Camera-following grid |
| Multiple Volumes | Supported | Scene with multiple DDGIVolumes |
| Bindless Resources | Optional | Descriptor heap mode |
| Shader Execution Reordering | Optional | NVIDIA Ada optimization |

---

## 9. KEY SHADER FILES

### 9.1 SDK Shaders (rtxgi-sdk/shaders/ddgi/)

| File | Size | Purpose |
|------|------|---------|
| ProbeBlendingCS.hlsl | 27KB | Core probe update |
| Irradiance.hlsl | 10KB | Sampling functions |
| ProbeClassificationCS.hlsl | | Probe validity |
| ProbeRelocationCS.hlsl | | Probe repositioning |

### 9.2 Test Harness Shaders

| File | Purpose |
|------|---------|
| ProbeTraceCS.hlsl | Inline ray tracing probe update |
| RadianceCacheCS.hlsl | Radiance cache compute shader |
| InlineRayTracingCommon.hlsl | RayQuery utilities |
| InlineLighting.hlsl | Shadow/visibility rays |

---

## 10. BUILD SYSTEM

### 10.1 CMake Options

```cmake
RTXGI_BUILD_SAMPLES          # Build test harness
RTXGI_API_D3D12_ENABLE       # D3D12 support
RTXGI_API_VULKAN_ENABLE      # Vulkan support
RTXGI_DDGI_RESOURCE_MANAGEMENT # SDK manages resources
RTXGI_COORDINATE_SYSTEM      # RH_YUp, LH_YUp, etc.
```

### 10.2 Dependencies

- Agility SDK (D3D12 runtime)
- DXC (HLSL compiler)
- Vulkan SDK
- GLFW, ImGui, TinyGLTF
- NVAPI (optional)

---

## 11. PERFORMANCE CONSIDERATIONS

### 11.1 GPU Workload Distribution

- Probe Ray Tracing: 40-50%
- Probe Blending: 20-30%
- Screen-space Gathering: 20-30%
- Optional passes: 5-10%

### 11.2 Optimization Techniques

1. Bindless Resources
2. Shared Memory in ProbeBlendingCS
3. Probe Classification (skip inactive)
4. Variability Tracking (skip converged)
5. Shader Execution Reordering (Ada)

---

## 12. RECENT MODIFICATIONS

**Branch:** feature/stable-radiance-cache

| Commit | Description |
|--------|-------------|
| 18b290b | Convert radiance cache to inline ray tracing |
| 6cab8c9 | Fix shader compiler errors |
| 33e5c2c | Add inline ray tracing compute shader support |

**Key Change:** Traditional DXR → Inline RayQuery compute shader

---

## 13. ARCHITECTURAL ANALYSIS

### 13.1 Strengths

- **Cross-platform abstraction:** Clean separation between D3D12 and Vulkan
- **Modular design:** SDK vs application code well separated
- **Comprehensive documentation:** Extensive docs for integration
- **Flexible resource management:** Managed vs Unmanaged modes
- **Modern GPU techniques:** Inline ray tracing, bindless resources

### 13.2 Areas for Improvement

1. **Async Compute:** Overlap probe blending with other GPU work
2. **Probe Streaming:** Dynamic load/unload for large scenes
3. **Adaptive Resolution:** Variable probe density based on importance
4. **Multi-GPU Support:** Distribute probe tracing across GPUs
5. **Temporal Stability:** Additional filtering for animation artifacts

### 13.3 Code Quality Observations

- Well-organized header hierarchy
- Consistent naming conventions
- Proper use of namespaces
- Clear separation of concerns
- GPU resource lifecycle well-managed

---

## 14. COMPONENT RELATIONSHIPS

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Scenes    │  │   Configs   │  │   Instrumentation   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Graphics Layer                          │
│  ┌─────────┐  ┌─────────┐  ┌──────┐  ┌───────────────────┐  │
│  │ GBuffer │  │  DDGI   │  │ RTAO │  │   PathTracing     │  │
│  └─────────┘  └─────────┘  └──────┘  └───────────────────┘  │
│                    │                                         │
│                    ▼                                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              DDGIVolume (SDK)                        │    │
│  │  ┌──────────────┐  ┌───────────────────────────┐    │    │
│  │  │ CPU Logic    │  │ GPU Resources              │    │    │
│  │  │ - Update     │  │ - Irradiance Texture      │    │    │
│  │  │ - Blending   │  │ - Distance Texture        │    │    │
│  │  │ - Relocation │  │ - Ray Data Texture        │    │    │
│  │  └──────────────┘  └───────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Platform Layer                          │
│        ┌──────────────┐        ┌──────────────┐             │
│        │    D3D12     │        │    Vulkan    │             │
│        └──────────────┘        └──────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

---

## 15. SHADER DEPENDENCY GRAPH

```
ProbeTraceCS.hlsl / ProbeTraceRGS.hlsl
    │
    ├── InlineRayTracingCommon.hlsl
    │       └── RayTracing.hlsl
    │
    ├── InlineLighting.hlsl
    │       └── Lighting.hlsl
    │               └── BRDF calculations
    │
    └── RadianceCommon.hlsl
            └── SpatialHash.hlsl

ProbeBlendingCS.hlsl
    │
    ├── ProbeCommon.hlsl
    ├── ProbeIndexing.hlsl
    ├── ProbeOctahedral.hlsl
    └── ProbeDataCommon.hlsl

Irradiance.hlsl (sampling)
    │
    ├── ProbeIndexing.hlsl
    ├── ProbeOctahedral.hlsl
    └── DDGIRootConstants.hlsl
```

---

## 16. REFERENCES

- `/docs/Algorithms.md` - Algorithm overview
- `/docs/DDGIVolume.md` - API reference (500+ lines)
- `/docs/Integration.md` - Integration guide
- `/docs/ShaderAPI.md` - Shader function reference

---

*Generated by Claude Code Architecture Review*
