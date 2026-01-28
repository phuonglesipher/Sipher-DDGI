# Plan: Shader Precompilation System

**Date**: 2026-01-28
**Goal**: Build hệ thống precompile shader tại build-time để:
1. Phát hiện lỗi shader sớm (trước khi chạy app)
2. Log chi tiết lỗi vào file để agent có thể debug
3. Giảm thời gian startup của app

---

## 1. Hiện Trạng

### Shader Compilation Hiện Tại
- **Runtime compilation**: Shader được compile khi app khởi động
- **Compiler**: DXC (DirectX Shader Compiler) v1.7.2308
- **Error handling**: Hiển thị popup dialog, không log ra file
- **36 shader files** cần compile (HLSL)

### Vấn Đề
- Lỗi shader chỉ phát hiện khi chạy app
- Không có log file để debug
- Agent khó debug vì không thể đọc popup dialog

---

## 2. Giải Pháp Đề Xuất

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     BUILD TIME                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  CMake Build                                                     │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────┐                                            │
│  │ ShaderCompiler  │  Standalone tool (ShaderCompiler.exe)      │
│  │ Tool            │  - Reads shader manifest (JSON/TOML)       │
│  └────────┬────────┘  - Compiles all shaders with DXC           │
│           │           - Outputs .dxil/.spv bytecode              │
│           │           - Logs to shader_compile.log               │
│           ▼                                                      │
│  ┌─────────────────┐     ┌─────────────────┐                    │
│  │ Compiled Shaders │     │ shader_compile  │                    │
│  │ (.dxil/.spv)     │     │ .log            │                    │
│  └─────────────────┘     └─────────────────┘                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     RUNTIME                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  App Startup                                                     │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────────┐                                            │
│  │ Load Precompiled │  If .dxil exists → Load bytecode          │
│  │ or Runtime       │  Else → Compile at runtime (fallback)     │
│  │ Compile          │                                            │
│  └─────────────────┘                                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Components

#### 2.1 Shader Manifest File (`shaders.json`)
```json
{
  "version": "1.0",
  "shaders": [
    {
      "name": "RadianceCacheCS",
      "path": "shaders/ddgi/RadianceCacheCS.hlsl",
      "entry": "CS",
      "profile": "cs_6_6",
      "defines": [
        "RTXGI_BINDLESS_TYPE=0",
        "RADIANCE_CACHE_CASCADE_COUNT=1"
      ]
    },
    {
      "name": "ProbeTraceCS",
      "path": "shaders/ddgi/ProbeTraceCS.hlsl",
      "entry": "CS",
      "profile": "cs_6_6",
      "defines": [...]
    }
    // ... more shaders
  ]
}
```

#### 2.2 Shader Compiler Tool (`tools/ShaderCompiler.cpp`)
- Standalone executable
- Reads shader manifest
- Compiles each shader with DXC
- Outputs bytecode to `compiled_shaders/` directory
- Writes detailed log to `shader_compile.log`

#### 2.3 Log Format (`shader_compile.log`)
```
================================================================================
Shader Compilation Log
Date: 2026-01-28 10:30:45
DXC Version: 1.7.2308
================================================================================

[OK] RadianceCacheCS (cs_6_6)
     Source: shaders/ddgi/RadianceCacheCS.hlsl
     Output: compiled_shaders/RadianceCacheCS.dxil
     Time: 0.234s

[ERROR] ProbeTraceCS (cs_6_6)
     Source: shaders/ddgi/ProbeTraceCS.hlsl
     Error: shaders/ddgi/ProbeTraceCS.hlsl:45:12: error: undeclared identifier 'foo'
            float3 result = foo(position);
                            ^~~

[WARNING] IndirectCS (cs_6_6)
     Source: shaders/IndirectCS.hlsl
     Warning: shaders/IndirectCS.hlsl:123:8: warning: implicit truncation of vector type
     Output: compiled_shaders/IndirectCS.dxil
     Time: 0.189s

================================================================================
Summary: 34 OK, 1 ERROR, 1 WARNING
================================================================================
```

#### 2.4 CMake Integration
```cmake
# Add custom target for shader compilation
add_custom_target(CompileShaders
    COMMAND ${CMAKE_BINARY_DIR}/tools/ShaderCompiler
            --manifest ${CMAKE_SOURCE_DIR}/samples/test-harness/shaders.json
            --output ${CMAKE_BINARY_DIR}/compiled_shaders
            --log ${CMAKE_BINARY_DIR}/shader_compile.log
    DEPENDS ShaderCompiler
    COMMENT "Compiling shaders..."
)

# Make main target depend on shader compilation
add_dependencies(TestHarness-D3D12 CompileShaders)
```

#### 2.5 Runtime Loader Updates (`Shaders.cpp`)
```cpp
bool LoadPrecompiledShader(ShaderProgram& shader, const std::string& cacheDir)
{
    std::string cachePath = cacheDir + "/" + shader.name + ".dxil";

    // Check if precompiled exists
    if (std::filesystem::exists(cachePath))
    {
        // Load bytecode from file
        std::ifstream file(cachePath, std::ios::binary);
        // ... load into shader.bytecode
        return true;
    }

    return false; // Fall back to runtime compile
}

bool Compile(ShaderCompiler& dxc, ShaderProgram& shader, bool warningsAsErrors)
{
    // Try loading precompiled first
    if (LoadPrecompiledShader(shader, "compiled_shaders"))
    {
        return true;
    }

    // Fall back to runtime compilation
    // ... existing code ...
}
```

---

## 3. Implementation Steps

### Phase 1: Shader Manifest (Day 1)
1. Create `shaders.json` với tất cả shader definitions
2. Extract defines từ code hiện tại (DDGI_D3D12.cpp, etc.)

### Phase 2: Compiler Tool Core (Day 2)
1. Create `tools/ShaderCompiler/` project
2. Implement manifest parser (JSON)
3. Implement DXC compilation wrapper
4. Implement log file writer

### Phase 3: Hash-based Caching (Day 3)
1. Implement `IncludeParser` - parse #include recursively
2. Implement `SHA256` hasher (or use xxHash for speed)
3. Implement `HashCache` - load/save shader_cache.json
4. Integrate hash check vào compilation flow

### Phase 4: CMake Integration (Day 4)
1. Add ShaderCompiler as CMake target
2. Add CompileShaders custom target
3. Add dependency to main executable
4. Copy cache file to output directory

### Phase 5: Runtime Updates (Day 4)
1. Add precompiled shader loader
2. Update `Shaders::Compile()` to check cache first
3. Add fallback to runtime compilation

### Phase 6: Testing & Polish (Day 5)
1. Test full rebuild
2. Test incremental rebuild (change 1 shader)
3. Test include dependency (change include file)
4. Test error scenarios
5. Document usage

---

## 4. File Structure

```
Sipher-DDGI/
├── tools/
│   └── ShaderCompiler/
│       ├── CMakeLists.txt
│       ├── main.cpp              # Entry point
│       ├── ShaderManifest.h/cpp  # JSON parsing
│       ├── Compiler.h/cpp        # DXC wrapper
│       ├── Logger.h/cpp          # Log file writer
│       ├── HashCache.h/cpp       # Hash-based caching
│       ├── IncludeParser.h/cpp   # #include dependency tracking
│       └── Hash.h/cpp            # SHA256/xxHash implementation
├── samples/test-harness/
│   ├── shaders.json              # Shader manifest
│   └── shaders/                  # Source shaders (unchanged)
└── Build/
    ├── compiled_shaders/         # Output bytecode (.dxil, .spv)
    ├── shader_cache.json         # Hash cache for incremental builds
    └── shader_compile.log        # Compilation log
```

---

## 5. Agent-Friendly Log Format

Log được thiết kế để agent có thể:
1. **Parse dễ dàng**: Dùng markers `[OK]`, `[ERROR]`, `[WARNING]`
2. **Locate lỗi nhanh**: Include file:line:column
3. **Suggest fixes**: Include context code snippet
4. **Track progress**: Summary ở cuối

---

## 6. User Decisions

| Question | Answer |
|----------|--------|
| Output format | **Both DXIL + SPIR-V** |
| Build integration | **Part of main build** (auto compile khi build project) |
| Runtime behavior | **Fallback to runtime compile** (nếu không có .dxil thì compile lúc chạy) |

---

## 7. Final Implementation Plan

### Files to Create

1. **`tools/ShaderCompiler/CMakeLists.txt`**
   - Standalone tool project
   - Link với DXC

2. **`tools/ShaderCompiler/main.cpp`**
   - Parse command line args
   - Load manifest
   - Compile all shaders
   - Write log file

3. **`tools/ShaderCompiler/ShaderManifest.h/cpp`**
   - Parse `shaders.json`
   - Store shader definitions

4. **`tools/ShaderCompiler/Compiler.h/cpp`**
   - Wrap DXC compilation
   - Output DXIL and SPIR-V

5. **`tools/ShaderCompiler/Logger.h/cpp`**
   - Write structured log file
   - Track OK/ERROR/WARNING counts

6. **`samples/test-harness/shaders.json`**
   - Manifest với tất cả 36 shaders
   - Defines cho mỗi shader

### Files to Modify

1. **`CMakeLists.txt`** (root)
   - Add `tools/ShaderCompiler` subdirectory

2. **`samples/test-harness/CMakeLists.txt`**
   - Add CompileShaders target
   - Add dependency to main executables

3. **`samples/test-harness/src/Shaders.cpp`**
   - Add `LoadPrecompiledShader()` function
   - Modify `Compile()` to check cache first

4. **`samples/test-harness/include/Shaders.h`**
   - Add declarations for new functions

---

## 8. Incremental Compilation (Hash-based)

### Mục tiêu
- Chỉ compile lại shader khi có thay đổi
- Giảm build time từ ~30s xuống ~1s cho incremental builds
- Track dependencies (include files)

### Hash Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│                    HASH COMPUTATION                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Shader Hash = SHA256(                                          │
│      source_file_content                                         │
│    + include_file_1_content                                      │
│    + include_file_2_content                                      │
│    + ...                                                         │
│    + defines_string                                              │
│    + compiler_flags_string                                       │
│  )                                                               │
│                                                                  │
│  Example:                                                        │
│  RadianceCacheCS.hlsl                                           │
│    ├── #include "Descriptors.hlsl"     ─┐                       │
│    ├── #include "SpatialHash.hlsl"      │ All content           │
│    ├── #include "InlineLighting.hlsl"   │ hashed together       │
│    └── defines: RTXGI_BINDLESS_TYPE=0  ─┘                       │
│                                                                  │
│  Hash = "a3f2b1c4d5e6..."                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Cache File Format (`shader_cache.json`)

```json
{
  "version": "1.0",
  "compiler_version": "1.7.2308",
  "entries": {
    "RadianceCacheCS": {
      "hash": "a3f2b1c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2",
      "source": "shaders/ddgi/RadianceCacheCS.hlsl",
      "includes": [
        "shaders/include/Descriptors.hlsl",
        "shaders/include/SpatialHash.hlsl",
        "shaders/include/InlineLighting.hlsl",
        "shaders/include/InlineRayTracingCommon.hlsl",
        "shaders/include/RadianceCommon.hlsl"
      ],
      "defines": ["RTXGI_BINDLESS_TYPE=0", "HLSL=1"],
      "output_dxil": "compiled_shaders/RadianceCacheCS.dxil",
      "output_spirv": "compiled_shaders/RadianceCacheCS.spv",
      "last_compiled": "2026-01-28T10:30:45Z"
    },
    "ProbeTraceCS": {
      "hash": "b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3",
      ...
    }
  }
}
```

### Compilation Flow with Hash Check

```
┌─────────────────────────────────────────────────────────────────┐
│                 INCREMENTAL COMPILATION FLOW                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  For each shader in manifest:                                    │
│                                                                  │
│  1. Parse #include directives recursively                        │
│     └── Build dependency list                                    │
│                                                                  │
│  2. Compute current hash                                         │
│     └── SHA256(source + includes + defines + flags)              │
│                                                                  │
│  3. Load cached hash from shader_cache.json                      │
│                                                                  │
│  4. Compare hashes                                               │
│     │                                                            │
│     ├── Hash MATCH ──────────────────────────────────────────►  │
│     │   [SKIP] "RadianceCacheCS: Up to date"                    │
│     │                                                            │
│     └── Hash MISMATCH ───────────────────────────────────────►  │
│         [COMPILE] "RadianceCacheCS: Recompiling..."             │
│         │                                                        │
│         ├── Success → Update cache with new hash                │
│         └── Failure → Log error, keep old cache                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Include Dependency Tracking

```cpp
// Recursive include parser
std::vector<std::string> ParseIncludes(const std::string& shaderPath)
{
    std::vector<std::string> includes;
    std::set<std::string> visited;  // Prevent infinite loops

    ParseIncludesRecursive(shaderPath, includes, visited);
    return includes;
}

void ParseIncludesRecursive(const std::string& path,
                            std::vector<std::string>& includes,
                            std::set<std::string>& visited)
{
    if (visited.count(path)) return;
    visited.insert(path);

    std::string content = ReadFile(path);

    // Regex: #include "path" or #include <path>
    std::regex includeRegex(R"(#include\s*[<"]([^>"]+)[>"])");

    for (auto match : std::sregex_iterator(content.begin(), content.end(), includeRegex))
    {
        std::string includePath = ResolveIncludePath(path, match[1].str());
        includes.push_back(includePath);
        ParseIncludesRecursive(includePath, includes, visited);
    }
}
```

### Hash Computation

```cpp
std::string ComputeShaderHash(const ShaderDefinition& shader)
{
    SHA256 hasher;

    // 1. Hash main source file
    hasher.update(ReadFile(shader.path));

    // 2. Hash all includes (in sorted order for determinism)
    auto includes = ParseIncludes(shader.path);
    std::sort(includes.begin(), includes.end());
    for (const auto& inc : includes)
    {
        hasher.update(ReadFile(inc));
    }

    // 3. Hash defines (sorted)
    auto defines = shader.defines;
    std::sort(defines.begin(), defines.end());
    for (const auto& def : defines)
    {
        hasher.update(def);
    }

    // 4. Hash compiler flags
    hasher.update(shader.profile);
    hasher.update(shader.entryPoint);

    return hasher.hexdigest();
}
```

### Log Format with Hash Status

```
================================================================================
Shader Compilation Log
Date: 2026-01-28 10:30:45
DXC Version: 1.7.2308
Mode: Incremental (hash-based)
================================================================================

[SKIP] RadianceCacheCS (cs_6_6)
     Status: Up to date (hash match)
     Hash: a3f2b1c4...

[SKIP] ProbeTraceCS (cs_6_6)
     Status: Up to date (hash match)
     Hash: b4c3d2e1...

[RECOMPILE] IndirectCS (cs_6_6)
     Status: Source changed
     Old hash: c5d4e3f2...
     New hash: d6e5f4a3...
     Changed files:
       - shaders/IndirectCS.hlsl (modified)
       - shaders/include/Lighting.hlsl (modified)
     Output: compiled_shaders/IndirectCS.dxil
     Time: 0.234s

[NEW] NewShaderCS (cs_6_6)
     Status: First compilation
     Hash: e7f6a5b4...
     Output: compiled_shaders/NewShaderCS.dxil
     Time: 0.189s

================================================================================
Summary: 32 SKIP, 1 RECOMPILE, 1 NEW, 0 ERROR
Total time: 0.423s (vs 28.5s full rebuild)
================================================================================
```

### Files to Add for Hash Support

1. **`tools/ShaderCompiler/HashCache.h/cpp`**
   ```cpp
   class HashCache {
   public:
       bool Load(const std::string& cachePath);
       bool Save(const std::string& cachePath);

       bool IsUpToDate(const std::string& shaderName, const std::string& currentHash);
       void UpdateHash(const std::string& shaderName, const ShaderCacheEntry& entry);

   private:
       std::map<std::string, ShaderCacheEntry> entries_;
       std::string compilerVersion_;
   };
   ```

2. **`tools/ShaderCompiler/IncludeParser.h/cpp`**
   ```cpp
   class IncludeParser {
   public:
       std::vector<std::string> ParseDependencies(const std::string& shaderPath);

   private:
       void ParseRecursive(const std::string& path,
                          std::vector<std::string>& deps,
                          std::set<std::string>& visited);
       std::string ResolvePath(const std::string& basePath, const std::string& includePath);
   };
   ```

3. **`tools/ShaderCompiler/SHA256.h/cpp`**
   - Use OpenSSL or standalone implementation
   - Or use std::hash for simpler (less secure but sufficient) approach

### Command Line Options

```bash
# Full rebuild (ignore cache)
ShaderCompiler --manifest shaders.json --output compiled_shaders --force

# Incremental build (default)
ShaderCompiler --manifest shaders.json --output compiled_shaders

# Show what would be compiled without actually compiling
ShaderCompiler --manifest shaders.json --dry-run

# Verbose mode - show hash computations
ShaderCompiler --manifest shaders.json --verbose
```

### Edge Cases Handled

| Case | Behavior |
|------|----------|
| New shader added | Compile (no cached hash) |
| Shader source changed | Recompile (hash mismatch) |
| Include file changed | Recompile all shaders that include it |
| Define changed | Recompile (defines are part of hash) |
| Compiler version changed | Recompile all (version in cache header) |
| Cache file missing | Full rebuild, create new cache |
| Cache file corrupted | Full rebuild, create new cache |
| Output .dxil missing | Recompile even if hash matches |
