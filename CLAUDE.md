# Sipher-DDGI Project Instructions

## Project Overview
RTXGI (Real-Time Global Illumination) implementation with DDGI (Dynamic Diffuse Global Illumination) and radiance caching.

## Build Commands

### Build Everything
```bash
cd "D:\Sipher-DDGI" && cmake --build build --config Release
```

### Build Test Harness Only
```bash
cd "D:\Sipher-DDGI" && cmake --build build --config Release --target TestHarness-D3D12
```

### Compile Shaders Only
```bash
powershell -Command "& 'D:\Sipher-DDGI\Build\tools\ShaderCompiler.exe' --manifest 'D:\Sipher-DDGI\samples\test-harness\shaders.json' --output 'D:\Sipher-DDGI\Build\compiled_shaders' --verbose 2>&1"
```

## Run Application
```bash
cd "D:\Sipher-DDGI\Build\samples\bin\d3d12\Release" && start TestHarness-D3D12.exe "D:/Sipher-DDGI/samples/test-harness/config/cornell.ini"
```

## Log Files

### Application Log (Agent-Friendly)
`D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\app_log.txt`

Format:
```
[TIMESTAMP] [LEVEL] [CATEGORY] MESSAGE (file:line)
```

Levels: DEBUG, INFO, WARNING, ERROR, FATAL

Special sections:
- `[SHADER_ERROR]` - Runtime shader compilation errors
- `[D3D12_DEVICE_REMOVED]` - GPU crash with reason
- `[CRASH]` - Unhandled exception with stack trace

### Shader Compile Log
`D:\Sipher-DDGI\shader_compile.log`

### Legacy Log
`D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\log.txt`

## Dev Loop Skill

To run the automated build-run-fix loop, use the following workflow:

1. **Compile Shaders** - Check for HLSL errors
2. **Build C++** - Check for compilation errors
3. **Run App** - Start the application
4. **Monitor Log** - Watch for crashes/errors
5. **Fix & Retry** - Auto-fix issues and loop

### How to Use

When user asks to build and run with auto-fix, or says "dev-loop":

1. Run shader compiler and check for errors
2. If shader errors, fix HLSL and retry
3. Run CMake build and check for errors
4. If C++ errors, fix code and retry
5. Start the app and wait 10-15 seconds
6. Read app_log.txt
7. If errors/crashes found, analyze and fix
8. Loop until app runs successfully

### Key Files

- Shaders: `samples/test-harness/shaders/`
- Shader Manifest: `samples/test-harness/shaders.json`
- C++ Source: `samples/test-harness/src/`
- Headers: `samples/test-harness/include/`
- DDGI Shaders: `samples/test-harness/shaders/ddgi/`
- RTXGI SDK: `rtxgi-sdk/`

## Common Issues

### Shader Compilation
- Missing defines in shaders.json
- Include path issues
- HLSL syntax errors

### D3D12 Device Removed
- DEVICE_HUNG: GPU timeout (infinite loop or very slow shader)
- INVALID_CALL: Wrong API usage
- DRIVER_INTERNAL_ERROR: Driver bug or hardware issue

### Crashes
- ACCESS_VIOLATION: Null pointer or buffer overflow
- Check stack trace for crash location
- Review recent log entries for context
