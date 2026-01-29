---
description: 'Build, run with debug capture, and analyze visual output'
---

# Visual Debug

Build, run with automatic debug capture, and analyze the visual output images.

## Instructions

You are a visual debugging assistant. Your job is to:
1. Compile and build the application
2. Run with `--debug-capture` mode
3. Wait for debug images to be captured
4. Analyze the captured images for issues
5. Report findings or auto-fix problems

### Step 1: Compile Shaders

Run the shader precompiler:
```bash
powershell -Command "& 'D:\Sipher-DDGI\Build\tools\ShaderCompiler.exe' --manifest 'D:\Sipher-DDGI\samples\test-harness\shaders.json' --output 'D:\Sipher-DDGI\Build\compiled_shaders' --verbose 2>&1"
```

If shader errors occur, fix them and retry.

### Step 2: Build C++ Code

Run CMake build:
```bash
cd "D:\Sipher-DDGI" && cmake --build build --config Release --target TestHarness-D3D12 2>&1
```

If build errors occur, fix them and retry.

### Step 3: Run with Debug Capture

Start the application with debug capture enabled:
```bash
cd "D:\Sipher-DDGI\Build\samples\bin\d3d12\Release" && TestHarness-D3D12.exe "D:/Sipher-DDGI/samples/test-harness/config/cornell.ini" --debug-capture --debug-output "visual_debug" --debug-frames 60
```

This will:
- Run the app for 60 frames (allowing GI to converge)
- Automatically capture debug images
- Exit when capture is complete

### Step 4: Wait for Capture Complete

Monitor the log for completion:
```bash
cat "D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\app_log.txt" | grep -E "(DEBUG_CAPTURE_COMPLETE|DebugCapture)"
```

When you see `=== DEBUG_CAPTURE_COMPLETE ===`, the images are ready.

### Step 5: Analyze Debug Images

The following images will be saved to `visual_debug/`:

| Image | Description | What to Look For |
|-------|-------------|------------------|
| `R-BackBuffer.png` | Final rendered output | Overall quality, artifacts, wrong colors |
| `DDGI-IndirectOutput.png` | Indirect lighting only | GI quality, light leaks, dark areas |
| `RadianceCache-Visualization.png` | Radiance cache cells | Cache coverage, missing cells, hash collisions |
| `DDGIVolume[*]-Irradiance.png` | Probe irradiance | Probe blending quality, light bleeding |
| `R-GBufferA.png` | Albedo | Material correctness |
| `R-GBufferB.png` | World position | Geometry correctness |
| `R-GBufferC.png` | Normals | Normal quality, artifacts |
| `R-GBufferD.png` | Direct lighting | Direct light quality |

Read each image using the Read tool and analyze:
```
Read visual_debug/R-BackBuffer.png
Read visual_debug/DDGI-IndirectOutput.png
Read visual_debug/RadianceCache-Visualization.png
```

### Step 6: Report Issues

Common issues to identify:

**Black/Dark Indirect Lighting:**
- Probes not updating
- Radiance cache not accumulating
- Hash collision issues

**Light Leaking:**
- Probes inside geometry
- Probe relocation needed
- Surface bias too small

**Noisy GI:**
- Not enough rays per probe
- Hysteresis too low
- Need more frames to converge

**Wrong Colors:**
- Material issues
- Light color problems
- Tone mapping errors

**Banding/Artifacts:**
- Texture format issues
- Quantization problems
- Interpolation errors

### Step 7: Auto-Fix or Report

If you identify the issue:
1. Explain what's wrong
2. Propose a fix
3. Implement the fix
4. Go back to Step 1 to verify

If unclear:
1. Report findings to user
2. Show relevant images
3. Ask for guidance

### Output Folder

Default: `D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\visual_debug`

Can be changed with `--debug-output <folder>` parameter.

### Frame Delay

Default: 60 frames (about 1 second at 60fps)

Can be changed with `--debug-frames <N>` parameter. Use higher values for:
- Scenes with complex lighting
- When radiance cache needs more time to fill
- When testing convergence behavior

### Tips

- Compare multiple captures to see temporal stability
- Check radiance cache coverage vs indirect lighting quality
- Look for correlation between probe irradiance and final output
- If final image looks correct but indirect is wrong, check composite shader
