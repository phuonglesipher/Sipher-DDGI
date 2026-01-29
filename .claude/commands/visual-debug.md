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
powershell -Command "& './Build/tools/ShaderCompiler.exe' --manifest './samples/test-harness/shaders.json' --output './Build/compiled_shaders' --verbose 2>&1"
```

If shader errors occur, fix them and retry.

### Step 2: Build C++ Code

Run CMake build:
```bash
cmake --build build --config Release --target TestHarness-D3D12 2>&1
```

If build errors occur, fix them and retry.

### Step 3: Run with Debug Capture

Start the application with debug capture enabled:
```bash
cd "./Build/samples/bin/d3d12/Release" && ./TestHarness-D3D12.exe "../../../../samples/test-harness/config/cornell.ini" --debug-capture --debug-output "visual_debug" --debug-frames 60
```

This will:
- Run the app for 60 frames (allowing GI to converge)
- Automatically capture debug images
- Exit when capture is complete

### Step 4: Wait for Capture Complete

Monitor the log for completion:
```bash
grep -E "(DEBUG_CAPTURE_COMPLETE|DebugCapture)" "./Build/samples/bin/d3d12/Release/app_log.txt"
```

When you see `=== DEBUG_CAPTURE_COMPLETE ===`, the images are ready.

### Step 5: Analyze Debug Images

The following images will be saved to `visual_debug/`:

| Image | Description | What to Look For |
|-------|-------------|------------------|
| `R-BackBuffer.png` | Final rendered output | Should look like RadianceCache-World but smoother |
| `IndirectLighting.png` | Indirect lighting only | Should show same colors as RadianceCache-World indirect |
| `RadianceCache-World.png` | World radiance cache visualization | Reference for indirect lighting colors |
| `DDGIVolume[*]-Irradiance-Layer-*.png` | Probe irradiance | Probe blending quality, light bleeding |
| `R-GBufferA.png` | Albedo | Material correctness |
| `R-GBufferB.png` | World position | Geometry correctness |
| `R-GBufferC.png` | Normals | Normal quality, artifacts |
| `R-GBufferD.png` | Direct lighting | Direct light quality |

Read images using the Read tool:
```
Read ./Build/samples/bin/d3d12/Release/visual_debug/R-BackBuffer.png
Read ./Build/samples/bin/d3d12/Release/visual_debug/IndirectLighting.png
Read ./Build/samples/bin/d3d12/Release/visual_debug/RadianceCache-World.png
```

### Step 6: Image Comparison Analysis

**CRITICAL: Follow this analysis workflow:**

#### 1. Compare Final Image vs World Radiance Cache
The final image (`R-BackBuffer.png`) should look similar to `RadianceCache-World.png` but **smoother**:
- Same color distribution (red bleeding near red walls, green near green walls)
- Smoother gradients (no blocky voxels)
- Proper surface shading applied

If final image does NOT match radiance cache colors:
- Check if indirect lighting is being applied
- Verify composite shader is combining correctly

#### 2. Compare Indirect Lighting vs World Radiance Cache
The indirect lighting (`IndirectLighting.png`) should show the **same color distribution** as `RadianceCache-World.png`:
- Red tints where radiance cache shows red
- Green tints where radiance cache shows green
- Similar intensity patterns

**BUG DETECTION:**
- If `RadianceCache-World.png` shows indirect colors BUT `IndirectLighting.png` is black/empty = **BUG!**
  - Indirect lighting is not being read from radiance cache
  - Check IndirectCS shader
  - Check DDGI output texture binding

- If both show colors but final image doesn't = **Composite shader bug**
  - Check how indirect is combined with direct lighting

#### 3. Check Probe Irradiance
The probe irradiance textures should show:
- Color variations matching the scene
- Not all black (probes not updating)
- Not all white (overflow/saturation issue)

### Step 7: Common Issues

**Black Indirect Lighting but Radiance Cache has colors:**
- IndirectCS not sampling radiance cache correctly
- Wrong buffer binding
- Shader compilation issue

**Final image missing GI colors:**
- Composite shader not using DDGI output
- Wrong blend mode
- Indirect multiplier set to 0

**Blocky/Voxelized final image:**
- Final gather downscale too high
- Interpolation disabled
- Wrong texture filtering

**Light Leaking:**
- Probes inside geometry
- Probe relocation needed
- Surface bias too small

**Noisy GI:**
- Not enough rays per probe
- Hysteresis too low
- Need more frames to converge

### Step 8: Auto-Fix or Report

If you identify the issue:
1. Explain what's wrong with image comparison evidence
2. Propose a fix
3. Implement the fix
4. Go back to Step 1 to verify

If unclear:
1. Report findings to user
2. Show relevant images side by side
3. Point out specific differences
4. Ask for guidance

### Output Folder

Default: `./Build/samples/bin/d3d12/Release/visual_debug`

Can be changed with `--debug-output <folder>` parameter.

### Frame Delay

Default: 60 frames (about 1 second at 60fps)

Can be changed with `--debug-frames <N>` parameter. Use higher values for:
- Scenes with complex lighting
- When radiance cache needs more time to fill
- When testing convergence behavior

### Quick Reference

```bash
# Full workflow
powershell -Command "& './Build/tools/ShaderCompiler.exe' --manifest './samples/test-harness/shaders.json' --output './Build/compiled_shaders' --verbose 2>&1"
cmake --build build --config Release --target TestHarness-D3D12
cd "./Build/samples/bin/d3d12/Release" && ./TestHarness-D3D12.exe "../../../../samples/test-harness/config/cornell.ini" --debug-capture --debug-frames 60

# Check results
ls ./Build/samples/bin/d3d12/Release/visual_debug/
```
