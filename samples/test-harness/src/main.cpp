/*
* Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "Common.h"
#include "Configs.h"
#include "Scenes.h"
#include "Inputs.h"
#include "Instrumentation.h"
#include "Graphics.h"
#include "UI.h"
#include "Window.h"
#include "Benchmark.h"
#include "AppLogger.h"

#include "graphics/PathTracing.h"
#include "graphics/GBuffer.h"
#include "graphics/DDGI.h"
#include "graphics/DDGIVisualizations.h"
#include "graphics/RTAO.h"
#include "graphics/Composite.h"

#include <filesystem>

#if _WIN32
extern "C" { __declspec(dllexport) extern const UINT D3D12SDKVersion = 606; }
extern "C" { __declspec(dllexport) extern const char* D3D12SDKPath = u8".\\D3D12\\"; }
#endif

void StoreImages(
    Inputs::EInputEvent& event,
    Configs::Config& config,
    Graphics::Globals& gfx,
    Graphics::GlobalResources& gfxResources,
    Graphics::RTAO::Resources& rtao,
    Graphics::DDGI::Resources& ddgi)
{
    if(config.app.benchmarkRunning) return; // Not allowed while benchmark is running

    std::filesystem::create_directories(config.scene.screenshotPath.c_str());

    if (event == Inputs::EInputEvent::SCREENSHOT)
    {
        Graphics::WriteBackBufferToDisk(gfx, config.scene.screenshotPath);
        event = Inputs::EInputEvent::NONE;
    }
    else if (event == Inputs::EInputEvent::SAVE_IMAGES)
    {
        Graphics::GBuffer::WriteGBufferToDisk(gfx, gfxResources, config.scene.screenshotPath);
        Graphics::RTAO::WriteRTAOBuffersToDisk(gfx, gfxResources, rtao, config.scene.screenshotPath);
        Graphics::DDGI::WriteVolumesToDisk(gfx, gfxResources, ddgi, config.scene.screenshotPath);
        event = Inputs::EInputEvent::NONE;
    }
}

/**
 * Run the Test Harness.
 */
int Run(const std::vector<std::string>& arguments)
{
    // Initialize the agent-friendly logger
    if (!AppLog::Logger::Instance().Initialize("app_log.txt"))
    {
        return EXIT_FAILURE;
    }
    LOG_INFO("App", "Application starting...");

    std::ofstream log;
    log.open("log.txt", std::ios::out);
    if (!log.is_open())
    {
        LOG_ERROR("App", "Failed to open log.txt");
        return EXIT_FAILURE;
    }

    // Global Data Structures
    Configs::Config config;
    Scenes::Scene scene;

    // Graphics Globals
    Graphics::Globals gfx;
    Graphics::GlobalResources gfxResources;

    // Graphics Workloads
    Graphics::PathTracing::Resources pt;
    Graphics::GBuffer::Resources gbuffer;
    Graphics::DDGI::Resources ddgi;
    Graphics::DDGI::Visualizations::Resources ddgiVis;
    Graphics::RTAO::Resources rtao;
    Graphics::Composite::Resources composite;
    Graphics::UI::Resources ui;

    // Performance Timers
    Instrumentation::Stat startupShutdown;
    Instrumentation::Performance perf;
    Instrumentation::Stat* frameStat = perf.AddCPUStat("Frame");
    Instrumentation::Stat* waitStat = perf.AddCPUStat("Wait For GPU");
    Instrumentation::Stat* resetStat = perf.AddCPUStat("Reset");
    Instrumentation::Stat* timestampBeginStat = perf.AddCPUStat("TimestampBegin");
    Instrumentation::Stat* inputStat = perf.AddCPUStat("Input");
    Instrumentation::Stat* updateStat = perf.AddCPUStat("Update");
    perf.AddGPUStat("Frame");

    Benchmark::BenchmarkRun benchmarkRun;

    CPU_TIMESTAMP_BEGIN(&startupShutdown);

    // Parse the command line and get the config file path
    log << "Parsing command line...";
    LOG_INFO("Init", "Parsing command line...");
    if (!Configs::ParseCommandLine(arguments, config, log))
    {
        log << "Failed to parse the command line!";
        LOG_ERROR("Init", "Failed to parse the command line");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("Init", "Command line parsed successfully");

    // Load and parse the config file
    log << "Loading config file...";
    LOG_INFO("Init", "Loading config file: " + config.app.filepath);
    if (!Configs::Load(config, log))
    {
        LOG_ERROR("Init", "Failed to load config file");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("Init", "Config loaded successfully");

    // Create a window
    log << "Creating a window...";
    LOG_INFO("Init", "Creating window (" + std::to_string(config.app.width) + "x" + std::to_string(config.app.height) + ")");
    if(!Windows::Create(config, gfx.window))
    {
        log << "\nFailed to create the window!";
        LOG_ERROR("Init", "Failed to create window");
        log.close();
        return EXIT_FAILURE;
    }

    log << "done.\n";
    LOG_INFO("Init", "Window created successfully");

    // Input
    log << "Initializing input system...";
    LOG_INFO("Init", "Initializing input system...");
    Inputs::Input input;
    if(!Inputs::Initialize(gfx.window, input, config, scene))
    {
        log << "\nFailed to initialize input!";
        LOG_ERROR("Init", "Failed to initialize input system");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("Init", "Input system initialized");

    // Create a device
    log << "Creating graphics device...";
    LOG_INFO("Graphics", "Creating D3D12 device...");
    if (!Graphics::CreateDevice(gfx, config))
    {
        log << "\nFailed to create the graphics device!";
        LOG_ERROR("Graphics", "Failed to create D3D12 device - check GPU drivers and DirectX 12 support");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("Graphics", "D3D12 device created successfully");

#ifdef GPU_COMPRESSION
    // Initialize the texture system
    log << "Initializing texture system...";
    if (!Textures::Initialize())
    {
        log << "\nFailed to initialize texture system!";
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
#endif

    // Initialize the scene
    log << "Initializing the scene...";
    LOG_INFO("Scene", "Initializing scene: " + config.scene.file);
    if (!Scenes::Initialize(config, scene, log))
    {
        log << "\nFailed to initialize the scene!";
        LOG_ERROR("Scene", "Failed to initialize scene - check scene file path and format");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("Scene", "Scene initialized: " + std::to_string(scene.meshes.size()) + " meshes, " + std::to_string(scene.textures.size()) + " textures");

    // Initialize the graphics system
    log << "Initializing graphics...";
    LOG_INFO("Graphics", "Initializing graphics resources...");
    if (!Graphics::Initialize(config, scene, gfx, gfxResources, log))
    {
        log << "\nFailed to initialize graphics!";
        LOG_ERROR("Graphics", "Failed to initialize graphics resources");
        log.close();
        return EXIT_FAILURE;
    }
    LOG_INFO("Graphics", "Graphics resources initialized");

    // Initialize the graphics workloads
    LOG_INFO("Graphics", "Initializing PathTracing workload...");
    CHECK(Graphics::PathTracing::Initialize(gfx, gfxResources, pt, perf, log), "initialize path tracing workload!\n", log);
    LOG_INFO("Graphics", "PathTracing initialized");

    LOG_INFO("Graphics", "Initializing GBuffer workload...");
    CHECK(Graphics::GBuffer::Initialize(gfx, gfxResources, gbuffer, perf, log), "initialize gbuffer workload!\n", log);
    LOG_INFO("Graphics", "GBuffer initialized");

    LOG_INFO("Graphics", "Initializing DDGI workload...");
    CHECK(Graphics::DDGI::Initialize(gfx, gfxResources, ddgi, config, perf, log), "initialize dynamic diffuse global illumination workload!\n", log);
    LOG_INFO("Graphics", "DDGI initialized with " + std::to_string(ddgi.volumes.size()) + " volumes");

    LOG_INFO("Graphics", "Initializing DDGI Visualizations...");
    CHECK(Graphics::DDGI::Visualizations::Initialize(gfx, gfxResources, ddgi, ddgiVis, perf, config, log), "initialize dynamic diffuse global illumination visualization workload!\n", log);
    LOG_INFO("Graphics", "DDGI Visualizations initialized");

    LOG_INFO("Graphics", "Initializing RTAO workload...");
    CHECK(Graphics::RTAO::Initialize(gfx, gfxResources, rtao, perf, log), "initialize ray traced ambient occlusion workload!\n", log);
    LOG_INFO("Graphics", "RTAO initialized");

    LOG_INFO("Graphics", "Initializing Composite workload...");
    CHECK(Graphics::Composite::Initialize(gfx, gfxResources, composite, perf, log), "initialize composition workload!\n", log);
    LOG_INFO("Graphics", "Composite initialized");

    // Initialize the user interface system
    log << "Initializing user interface...";
    LOG_INFO("UI", "Initializing user interface...");
    if (!Graphics::UI::Initialize(gfx, gfxResources, ui, perf, log))
    {
        log << "\nFailed to initialize user interface!";
        LOG_ERROR("UI", "Failed to initialize user interface");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done.\n";
    LOG_INFO("UI", "User interface initialized");

    log << "Post initialization...";
    LOG_INFO("Graphics", "Post initialization...");
    if (!Graphics::PostInitialize(gfx, log))
    {
        log << "\nFailed post-initialize!";
        LOG_ERROR("Graphics", "Post initialization failed");
        log.close();
        return EXIT_FAILURE;
    }
    log << "done\n";
    LOG_INFO("Graphics", "Post initialization complete");

    // Add a few more CPU stats
    Instrumentation::Stat* timestampEndStat = perf.AddCPUStat("TimestampEnd");
    Instrumentation::Stat* submitStat = perf.AddCPUStat("Submit");
    Instrumentation::Stat* presentStat = perf.AddCPUStat("Present");

    CPU_TIMESTAMP_END(&startupShutdown);
    log << "Startup complete in " << startupShutdown.elapsed << " milliseconds\n";

    log << "Main loop...\n";
    std::flush(log);
    LOG_INFO("App", "Entering main loop");

    // Main loop
    while(!glfwWindowShouldClose(gfx.window))
    {
        CPU_TIMESTAMP_BEGIN(frameStat);

        // Wait for the previous frame's GPU work to complete
        CPU_TIMESTAMP_BEGIN(waitStat);
        if (!Graphics::WaitForPrevGPUFrame(gfx))
        {
            log << "GPU took too long to complete, device removed!";
            LOG_FATAL("Graphics", "GPU device removed - WaitForPrevGPUFrame failed");
#ifdef _WIN32
            LOG_D3D12_DEVICE_REMOVED(gfx.device);
#endif
            break;
        }
        CPU_TIMESTAMP_ENDANDRESOLVE(waitStat);

        // Move to the next frame and reset the frame's command list
        CPU_TIMESTAMP_BEGIN(resetStat);
        if (!Graphics::MoveToNextFrame(gfx))
        {
            LOG_ERROR("Graphics", "MoveToNextFrame failed");
            break;
        }
        if (!Graphics::ResetCmdList(gfx))
        {
            LOG_ERROR("Graphics", "ResetCmdList failed");
            break;
        }
        CPU_TIMESTAMP_ENDANDRESOLVE(resetStat);

        CPU_TIMESTAMP_BEGIN(timestampBeginStat);
    #ifdef GFX_PERF_INSTRUMENTATION
        if (!Graphics::UpdateTimestamps(gfx, gfxResources, perf)) break;
        Graphics::BeginFrame(gfx, gfxResources, perf);
    #endif
        CPU_TIMESTAMP_ENDANDRESOLVE(timestampBeginStat);

        // Reload shaders, recreate PSOs, and update shader tables
        {
            if (config.pathTrace.reload)
            {
                LOG_INFO("Shaders", "Reloading PathTracing shaders...");
                if (!Graphics::PathTracing::Reload(gfx, gfxResources, pt, log))
                {
                    LOG_ERROR("Shaders", "Failed to reload PathTracing shaders");
                    break;
                }
                config.pathTrace.reload = false;
                LOG_INFO("Shaders", "PathTracing shaders reloaded successfully");
            }

            if (config.ddgi.reload)
            {
                LOG_INFO("Shaders", "Reloading DDGI shaders...");
                if (!Graphics::DDGI::Reload(gfx, gfxResources, ddgi, config, log))
                {
                    LOG_ERROR("Shaders", "Failed to reload DDGI shaders");
                    break;
                }
                if (!Graphics::DDGI::Visualizations::Reload(gfx, gfxResources, ddgi, ddgiVis, config, log))
                {
                    LOG_ERROR("Shaders", "Failed to reload DDGI Visualization shaders");
                    break;
                }
                config.ddgi.reload = false;
                LOG_INFO("Shaders", "DDGI shaders reloaded successfully");
            }

            if (config.rtao.reload)
            {
                LOG_INFO("Shaders", "Reloading RTAO shaders...");
                if (!Graphics::RTAO::Reload(gfx, gfxResources, rtao, log))
                {
                    LOG_ERROR("Shaders", "Failed to reload RTAO shaders");
                    break;
                }
                config.rtao.reload = false;
                LOG_INFO("Shaders", "RTAO shaders reloaded successfully");
            }

            if (config.postProcess.reload)
            {
                LOG_INFO("Shaders", "Reloading Composite shaders...");
                if (!Graphics::Composite::Reload(gfx, gfxResources, composite, log))
                {
                    LOG_ERROR("Shaders", "Failed to reload Composite shaders");
                    break;
                }
                config.postProcess.reload = false;
                LOG_INFO("Shaders", "Composite shaders reloaded successfully");
            }
        }

        CPU_TIMESTAMP_BEGIN(inputStat);

        glfwPollEvents();

        // Exit the application
        if (input.event == Inputs::EInputEvent::QUIT) break;

        // Initialize the benchmark
        if (!config.app.benchmarkRunning && input.event == Inputs::EInputEvent::RUN_BENCHMARK)
        {
            Benchmark::StartBenchmark(benchmarkRun, perf, config, gfx);
            input.event = Inputs::EInputEvent::NONE;
        }

        // Handle mouse and keyboard input
        Inputs::PollInputs(gfx.window);

        // Reset the frame number on camera movement (for path tracer accumulation reset)
        if (input.event == Inputs::EInputEvent::CAMERA_MOVEMENT)
        {
            gfx.frameNumber = 1;
            input.event = Inputs::EInputEvent::NONE;
        }

        CPU_TIMESTAMP_ENDANDRESOLVE(inputStat);

        // Update the simulation / constant buffers
        CPU_TIMESTAMP_BEGIN(updateStat);
        Graphics::Update(gfx, gfxResources, config, scene);
        CPU_TIMESTAMP_ENDANDRESOLVE(updateStat);

        if(config.app.renderMode == ERenderMode::PATH_TRACE)
        {
            Graphics::PathTracing::Update(gfx, gfxResources, pt, config);
            Graphics::PathTracing::Execute(gfx, gfxResources, pt);
        }
        else if(config.app.renderMode == ERenderMode::DDGI)
        {
            // GBuffer
            Graphics::GBuffer::Update(gfx, gfxResources, gbuffer, config);
            Graphics::GBuffer::Execute(gfx, gfxResources, gbuffer);

            // RTXGI: DDGI
            Graphics::DDGI::Update(gfx, gfxResources, ddgi, config, scene);
            Graphics::DDGI::Execute(gfx, gfxResources, ddgi);

            // RTXGI: DDGI Visualizations
            Graphics::DDGI::Visualizations::Update(gfx, gfxResources, ddgiVis, config);
            Graphics::DDGI::Visualizations::Execute(gfx, gfxResources, ddgiVis);

            // Ray Traced Ambient Occlusion
            Graphics::RTAO::Update(gfx, gfxResources, rtao, config);
            Graphics::RTAO::Execute(gfx, gfxResources, rtao);

            // Composite & Post Processing
            Graphics::Composite::Update(gfx, gfxResources, composite, config);
            Graphics::Composite::Execute(gfx, gfxResources, composite);
        }

        // UI
        CPU_TIMESTAMP_BEGIN(perf.cpuTimes[Instrumentation::EStatIndex::UI]);
        Graphics::UI::Update(gfx, ui, config, input, scene, ddgi.volumes, perf);
        Graphics::UI::Execute(gfx, gfxResources, ui, config);
        CPU_TIMESTAMP_ENDANDRESOLVE(perf.cpuTimes[Instrumentation::EStatIndex::UI]);

        // GPU Timestamps
        CPU_TIMESTAMP_BEGIN(timestampEndStat);
    #ifdef GFX_PERF_INSTRUMENTATION
        Graphics::EndFrame(gfx, gfxResources, perf);
        Graphics::ResolveTimestamps(gfx, gfxResources, perf);
    #endif
        CPU_TIMESTAMP_ENDANDRESOLVE(timestampEndStat);

        // Submit
        CPU_TIMESTAMP_BEGIN(submitStat);
        if (!Graphics::SubmitCmdList(gfx))
        {
            LOG_ERROR("Graphics", "SubmitCmdList failed");
#ifdef _WIN32
            LOG_D3D12_DEVICE_REMOVED(gfx.device);
#endif
            break;
        }
        CPU_TIMESTAMP_ENDANDRESOLVE(submitStat);

        // Present
        CPU_TIMESTAMP_BEGIN(presentStat);
        if (!Graphics::Present(gfx))
        {
            LOG_WARNING("Graphics", "Present failed - may recover on next frame");
            continue;
        }
        CPU_TIMESTAMP_ENDANDRESOLVE(presentStat);
        CPU_TIMESTAMP_ENDANDRESOLVE(frameStat); // end of frame

        // Handle window resize events
        if (Windows::GetWindowEvent() == Windows::EWindowEvent::RESIZE)
        {
            // Get the new back buffer dimensions from GLFW
            int width, height;
            glfwGetFramebufferSize(gfx.window, &width, &height);

            // Wait for the window to have valid dimensions
            while (width == 0 || height == 0)
            {
                glfwGetFramebufferSize(gfx.window, &width, &height);
                glfwWaitEvents();
            }

            // Resize all screen-space buffers
            if (!Graphics::ResizeBegin(gfx, gfxResources, width, height, log)) break;             // Back buffers and GBuffer textures
            if (!Graphics::PathTracing::Resize(gfx, gfxResources, pt, log)) break;                // PT Output and Accumulation
            if (!Graphics::GBuffer::Resize(gfx, gfxResources, gbuffer, log)) break;               // GBuffer
            if (!Graphics::DDGI::Resize(gfx, gfxResources, ddgi, log)) break;                     // DDGI
            if (!Graphics::DDGI::Visualizations::Resize(gfx, gfxResources, ddgiVis, log)) break;  // DDGI Visualizations
            if (!Graphics::RTAO::Resize(gfx, gfxResources, rtao, log)) break;                     // RTAO Raw and Output textures
            if (!Graphics::Composite::Resize(gfx, gfxResources, composite, log)) break;           // Composite
            if (!Graphics::ResizeEnd(gfx)) break;
            Windows::ResetWindowEvent();
        }

        // Fullscreen transition
        if (input.event == Inputs::EInputEvent::FULLSCREEN_CHANGE || gfx.fullscreenChanged)
        {
            Graphics::ToggleFullscreen(gfx);
            input.event = Inputs::EInputEvent::NONE;
        }

        // Image Capture (user triggered)
        if (input.event == Inputs::EInputEvent::SAVE_IMAGES || input.event == Inputs::EInputEvent::SCREENSHOT)
        {
            StoreImages(input.event, config, gfx, gfxResources, rtao, ddgi);
        }

    #ifdef GFX_PERF_INSTRUMENTATION
        if (config.app.benchmarkRunning)
        {
            if (Benchmark::UpdateBenchmark(benchmarkRun, perf, config, gfx, log))
            {
                // Store intermediate images when the benchmark ends
                Inputs::EInputEvent e = Inputs::EInputEvent::SCREENSHOT;
                StoreImages(e, config, gfx, gfxResources, rtao, ddgi);

                e = Inputs::EInputEvent::SAVE_IMAGES;
                StoreImages(e, config, gfx, gfxResources, rtao, ddgi);
            }
        }
    #endif
    }

    Graphics::WaitForGPU(gfx);

    CPU_TIMESTAMP_BEGIN(&startupShutdown);

    log << "Shutting down and cleaning up...\n";
    LOG_INFO("App", "Shutting down and cleaning up...");

    perf.Cleanup();

    Graphics::UI::Cleanup();
    Graphics::Composite::Cleanup(gfx, composite);
    Graphics::RTAO::Cleanup(gfx, rtao);
    Graphics::DDGI::Visualizations::Cleanup(gfx, ddgiVis);
    Graphics::DDGI::Cleanup(gfx, ddgi);
    Graphics::GBuffer::Cleanup(gfx, gbuffer);
    Graphics::PathTracing::Cleanup(gfx, pt);
    Graphics::Cleanup(gfx, gfxResources);

#ifdef GPU_COMPRESSION
    Textures::Cleanup();
#endif

    Windows::Close(gfx.window);

    CPU_TIMESTAMP_END(&startupShutdown);
    log << "Shutdown complete in " << startupShutdown.elapsed << " milliseconds\n";
    LOG_INFO("App", "Shutdown complete in " + std::to_string(startupShutdown.elapsed) + " milliseconds");

    log << "Done.\n";
    log.close();

    LOG_INFO("App", "Application exiting normally");
    AppLog::Logger::Instance().Shutdown();

    return EXIT_SUCCESS;
}

/**
 * Test Harness entry point.
 */
#if defined(_WIN32) || defined(WIN32)
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPWSTR lpCmdLine, int nCmdShow)
{
    UNREFERENCED_PARAMETER(hPrevInstance);
    UNREFERENCED_PARAMETER(lpCmdLine);

#if _DEBUG
    // Set CRT flags to automatically check for memory leaks at program termination
    int flags = _CrtSetDbgFlag(_CRTDBG_REPORT_FLAG);
    flags = (flags & 0x0000FFFF) | _CRTDBG_LEAK_CHECK_DF;
    _CrtSetDbgFlag(flags);
#endif

    // Convert command line arguments to vector
    char arg[256];
    std::vector<std::string> arguments;
    for(int i = 1; i < __argc; i++)
    {
        size_t len;
        size_t max = wcslen(__wargv[i]) + 1;
        memset(&arg, 0, 256);
        wcstombs_s(&len, arg, max, __wargv[i], max);
        arguments.push_back(std::string(arg));
    }

#elif __linux__
int main(int argc, char* argv[])
{
#if _DEBUG
    // TODO: Set flags to automatically check for memory leaks at program termination
#endif

    // Add command line arguments to vector
    std::vector<std::string> arguments;
    for(int i = 1; i < argc; i++)
    {
        arguments.push_back(std::string(argv[i]));
    }

#else
    #pragma message("Platform not supported!")
#endif

    // Run the application
    int result = Run(arguments);

    // If an error occurred, spawn a message box
    if (result != EXIT_SUCCESS)
    {
        std::string msg = "An error occurred. See log.txt for details.";
        Graphics::UI::MessageBox(msg);
    }

    return EXIT_SUCCESS;
}

