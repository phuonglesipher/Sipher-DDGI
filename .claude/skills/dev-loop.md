# Dev Loop Skill

Build, run, and auto-fix the Sipher-DDGI application.

## Trigger
User says: /dev-loop, /build-run, /run-fix, or asks to build and run the app with auto-fix

## Instructions

You are a development loop assistant. Your job is to:
1. Compile shaders
2. Build C++ code
3. Run the application
4. Monitor logs for crashes/errors
5. Auto-fix issues and retry

### Step 1: Compile Shaders

Run the shader precompiler:
```bash
powershell -Command "& 'D:\Sipher-DDGI\Build\tools\ShaderCompiler.exe' --manifest 'D:\Sipher-DDGI\samples\test-harness\shaders.json' --output 'D:\Sipher-DDGI\Build\compiled_shaders' --verbose 2>&1"
```

Check `shader_compile.log` for errors. If there are shader compilation errors:
- Read the error messages
- Identify the shader file and line number
- Fix the HLSL code
- Re-run shader compilation
- Loop until all shaders compile

### Step 2: Build C++ Code

Run CMake build:
```bash
cd "D:\Sipher-DDGI" && cmake --build build --config Release --target TestHarness-D3D12 2>&1
```

If there are C++ compilation errors:
- Read the error messages
- Identify the source file and line number
- Fix the C++ code
- Re-run build
- Loop until build succeeds

### Step 3: Run Application

Start the application:
```bash
cd "D:\Sipher-DDGI\Build\samples\bin\d3d12\Release" && start TestHarness-D3D12.exe "D:/Sipher-DDGI/samples/test-harness/config/cornell.ini"
```

### Step 4: Monitor Application Log

Wait 10-15 seconds for the app to initialize, then read the log:
```bash
cat "D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\app_log.txt"
```

Check for:
- `[ERROR]` entries - indicate runtime errors
- `[FATAL]` entries - indicate crashes
- `[CRASH]` section - indicates unhandled exception with stack trace
- `[D3D12_DEVICE_REMOVED]` - indicates GPU crash
- `[SHADER_ERROR]` - indicates runtime shader compilation failure

### Step 5: Handle Errors

If errors are found in the log:

1. **Shader Errors**:
   - Look for `[SHADER_ERROR]` blocks
   - Fix the HLSL code based on error message
   - Go back to Step 1

2. **D3D12 Device Removed**:
   - Look for `[D3D12_DEVICE_REMOVED]` block
   - Check the reason (DEVICE_HUNG, INVALID_CALL, etc.)
   - Review recent log entries for clues
   - Fix the issue in C++ or shader code
   - Go back to Step 1

3. **Crash/Exception**:
   - Look for `[CRASH]` block
   - Check exception type (ACCESS_VIOLATION, etc.)
   - Review stack trace for crash location
   - Review recent log entries
   - Fix the issue
   - Go back to Step 1

4. **Runtime Errors**:
   - Look for `[ERROR]` or `[FATAL]` entries
   - Fix based on error message and file/line info
   - Go back to Step 1

### Step 6: Success

If the log shows:
- `Entering main loop` - app started successfully
- No `[ERROR]`, `[FATAL]`, `[CRASH]` entries
- Eventually `Application exiting normally` when user closes

Report success to the user.

### Log File Locations

- App Log: `D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\app_log.txt`
- Legacy Log: `D:\Sipher-DDGI\Build\samples\bin\d3d12\Release\log.txt`
- Shader Log: `D:\Sipher-DDGI\shader_compile.log`

### Important Notes

- Always flush/re-read logs to get latest content
- The app runs in a separate window - use `start` command
- To stop the app, use Task Manager or let user close it
- Maximum 5 fix attempts per error type before asking user for help
- Report progress to user at each step
