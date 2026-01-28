/*
 * Shader Precompiler Tool
 *
 * Compiles HLSL shaders at build time with:
 * - Hash-based incremental compilation
 * - DXIL (D3D12) and SPIR-V (Vulkan) output
 * - Detailed logging for agent debugging
 *
 * Usage:
 *   ShaderCompiler --manifest shaders.json --output compiled_shaders [options]
 *
 * Options:
 *   --manifest <path>   Path to shader manifest JSON file
 *   --output <dir>      Output directory for compiled shaders
 *   --log <path>        Path to log file (default: shader_compile.log)
 *   --cache <path>      Path to hash cache file (default: shader_cache.json)
 *   --force             Force full rebuild (ignore cache)
 *   --verbose           Verbose output
 *   --dry-run           Show what would be compiled without compiling
 */

#include <iostream>
#include <string>
#include <vector>
#include <chrono>
#include <filesystem>

#include "ShaderManifest.h"
#include "Compiler.h"
#include "Logger.h"
#include "HashCache.h"
#include "IncludeParser.h"
#include "Hash.h"

namespace fs = std::filesystem;

struct Options
{
    std::string manifestPath;
    std::string outputDir;
    std::string logPath = "shader_compile.log";
    std::string cachePath = "shader_cache.json";
    bool force = false;
    bool verbose = false;
    bool dryRun = false;
};

bool ParseArgs(int argc, char* argv[], Options& opts)
{
    for (int i = 1; i < argc; ++i)
    {
        std::string arg = argv[i];

        if (arg == "--manifest" && i + 1 < argc)
        {
            opts.manifestPath = argv[++i];
        }
        else if (arg == "--output" && i + 1 < argc)
        {
            opts.outputDir = argv[++i];
        }
        else if (arg == "--log" && i + 1 < argc)
        {
            opts.logPath = argv[++i];
        }
        else if (arg == "--cache" && i + 1 < argc)
        {
            opts.cachePath = argv[++i];
        }
        else if (arg == "--force")
        {
            opts.force = true;
        }
        else if (arg == "--verbose")
        {
            opts.verbose = true;
        }
        else if (arg == "--dry-run")
        {
            opts.dryRun = true;
        }
        else if (arg == "--help" || arg == "-h")
        {
            std::cout << "Usage: ShaderCompiler --manifest <path> --output <dir> [options]\n";
            std::cout << "\nOptions:\n";
            std::cout << "  --manifest <path>   Path to shader manifest JSON file\n";
            std::cout << "  --output <dir>      Output directory for compiled shaders\n";
            std::cout << "  --log <path>        Path to log file (default: shader_compile.log)\n";
            std::cout << "  --cache <path>      Path to hash cache file (default: shader_cache.json)\n";
            std::cout << "  --force             Force full rebuild (ignore cache)\n";
            std::cout << "  --verbose           Verbose output\n";
            std::cout << "  --dry-run           Show what would be compiled without compiling\n";
            return false;
        }
    }

    if (opts.manifestPath.empty() || opts.outputDir.empty())
    {
        std::cerr << "Error: --manifest and --output are required\n";
        return false;
    }

    return true;
}

std::string GetCurrentDateTime()
{
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    char buffer[64];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&time));
    return buffer;
}

int main(int argc, char* argv[])
{
    Options opts;
    if (!ParseArgs(argc, argv, opts))
    {
        return 1;
    }

    std::cout << "=== Shader Precompiler ===\n";

    // Load manifest
    ShaderManifest manifest;
    if (!manifest.Load(opts.manifestPath))
    {
        std::cerr << "Error: Failed to load manifest: " << opts.manifestPath << "\n";
        return 1;
    }

    std::cout << "Loaded " << manifest.GetShaders().size() << " shader definitions\n";

    // Get project root (manifest is in samples/test-harness, so go up 2 levels)
    fs::path manifestAbsPath = fs::absolute(opts.manifestPath);
    std::string projectRoot = manifestAbsPath.parent_path().parent_path().parent_path().string();

    // Initialize compiler
    Compiler compiler;
    if (!opts.dryRun && !compiler.Initialize(projectRoot))
    {
        std::cerr << "Error: Failed to initialize compiler: " << compiler.GetLastError() << "\n";
        return 1;
    }

    std::string compilerVersion = compiler.GetVersion();

    // Load hash cache
    HashCache cache;
    cache.SetCompilerVersion(compilerVersion);

    bool cacheLoaded = cache.Load(opts.cachePath);
    bool forceRebuild = opts.force;

    if (cacheLoaded && cache.CompilerVersionChanged(compilerVersion))
    {
        std::cout << "Compiler version changed, forcing full rebuild\n";
        forceRebuild = true;
    }

    // Setup logger
    Logger logger;
    logger.SetCompilerVersion(compilerVersion);
    logger.SetIncrementalMode(!forceRebuild);

    // Setup include parser
    IncludeParser includeParser;
    std::string shaderDir = manifest.GetBasePath();
    std::string rtxgiDir = shaderDir + "/../../rtxgi-sdk";  // Relative to test-harness

    includeParser.AddIncludeDirectory(shaderDir);
    includeParser.AddIncludeDirectory(shaderDir + "/include");
    includeParser.AddIncludeDirectory(shaderDir + "/shaders");
    includeParser.AddIncludeDirectory(shaderDir + "/shaders/include");
    includeParser.AddIncludeDirectory(shaderDir + "/shaders/ddgi");
    includeParser.AddIncludeDirectory(shaderDir + "/../../include");
    includeParser.AddIncludeDirectory(shaderDir + "/../../include/graphics");
    includeParser.AddIncludeDirectory(rtxgiDir + "/include");
    includeParser.AddIncludeDirectory(rtxgiDir + "/shaders");

    // Create output directory
    fs::create_directories(opts.outputDir);

    // Process each shader
    int compiled = 0;
    int skipped = 0;
    int errors = 0;

    for (const auto& shader : manifest.GetShaders())
    {
        std::string sourcePath = shaderDir + "/" + shader.path;

        if (!fs::exists(sourcePath))
        {
            LogEntry entry;
            entry.status = LogStatus::STATUS_ERROR;
            entry.shaderName = shader.name;
            entry.profile = shader.profile;
            entry.sourcePath = shader.path;
            entry.message = "Source file not found: " + sourcePath;
            logger.AddEntry(entry);

            std::cerr << "[ERROR] " << shader.name << ": Source file not found\n";
            errors++;
            continue;
        }

        // Parse includes
        auto includes = includeParser.ParseDependencies(sourcePath);

        // Compute hash
        std::string currentHash = Hash::ComputeShaderHash(
            sourcePath, includes, shader.defines, shader.profile, shader.entryPoint);

        std::string cachedHash = cache.GetCachedHash(shader.name);

        // Check if up to date
        std::string dxilOutput = opts.outputDir + "/" + shader.name + ".dxil";
        std::string spirvOutput = opts.outputDir + "/" + shader.name + ".spv";

        bool needsCompile = forceRebuild || !cache.IsUpToDate(shader.name, currentHash);
        bool isNew = !cache.HasEntry(shader.name);

        if (!needsCompile)
        {
            // Skip - up to date
            LogEntry entry;
            entry.status = LogStatus::STATUS_SKIP;
            entry.shaderName = shader.name;
            entry.profile = shader.profile;
            entry.sourcePath = shader.path;
            entry.newHash = currentHash;
            logger.AddEntry(entry);

            if (opts.verbose)
            {
                std::cout << "[SKIP] " << shader.name << " (up to date)\n";
            }
            skipped++;
            continue;
        }

        if (opts.dryRun)
        {
            std::cout << "[WOULD COMPILE] " << shader.name << "\n";
            continue;
        }

        // Compile DXIL
        if (opts.verbose)
        {
            std::cout << "[COMPILE] " << shader.name << " -> DXIL\n";
        }

        // Get shader's directory for relative includes
        fs::path shaderPath(sourcePath);
        std::string shaderParentDir = shaderPath.parent_path().string();
        std::string rtxgiDir = shaderDir + "/../../rtxgi-sdk";

        std::vector<std::string> includeDirs = {
            shaderDir,
            shaderDir + "/include",
            shaderDir + "/shaders",
            shaderDir + "/shaders/include",
            shaderDir + "/shaders/ddgi",
            shaderDir + "/../..",  // For samples/test-harness relative paths
            shaderDir + "/../../include",  // For Types.h etc
            shaderDir + "/../../include/graphics",
            rtxgiDir + "/include",
            rtxgiDir + "/shaders",
            rtxgiDir + "/shaders/ddgi",
            rtxgiDir + "/shaders/ddgi/include",
            shaderParentDir,
            shaderParentDir + "/../include",
            shaderParentDir + "/../../include"
        };

        auto dxilResult = compiler.CompileDXIL(
            sourcePath, shader.entryPoint, shader.profile, shader.defines, includeDirs);

        if (!dxilResult.success)
        {
            LogEntry entry;
            entry.status = LogStatus::STATUS_ERROR;
            entry.shaderName = shader.name;
            entry.profile = shader.profile;
            entry.sourcePath = shader.path;
            entry.message = dxilResult.errorMessage;
            logger.AddEntry(entry);

            std::cerr << "[ERROR] " << shader.name << ": " << dxilResult.errorMessage << "\n";
            errors++;
            continue;
        }

        // Save DXIL
        if (!compiler.SaveBytecode(dxilResult.bytecode, dxilOutput))
        {
            std::cerr << "[ERROR] " << shader.name << ": Failed to save DXIL\n";
            errors++;
            continue;
        }

        // Compile SPIR-V if requested
        double totalTime = dxilResult.compileTime;

        if (shader.generateSpirv)
        {
            if (opts.verbose)
            {
                std::cout << "[COMPILE] " << shader.name << " -> SPIR-V\n";
            }

            auto spirvResult = compiler.CompileSPIRV(
                sourcePath, shader.entryPoint, shader.profile, shader.defines, includeDirs);

            if (spirvResult.success)
            {
                compiler.SaveBytecode(spirvResult.bytecode, spirvOutput);
                totalTime += spirvResult.compileTime;
            }
            else
            {
                std::cerr << "[WARNING] " << shader.name << ": SPIR-V compilation failed\n";
            }
        }

        // Update cache
        ShaderCacheEntry cacheEntry;
        cacheEntry.hash = currentHash;
        cacheEntry.sourcePath = shader.path;
        cacheEntry.includes.assign(includes.begin(), includes.end());
        cacheEntry.defines = shader.defines;
        cacheEntry.outputDxil = dxilOutput;
        cacheEntry.outputSpirv = shader.generateSpirv ? spirvOutput : "";
        cacheEntry.lastCompiled = GetCurrentDateTime();
        cache.UpdateEntry(shader.name, cacheEntry);

        // Log entry
        LogEntry entry;
        entry.status = isNew ? LogStatus::STATUS_NEW : LogStatus::STATUS_RECOMPILE;
        entry.shaderName = shader.name;
        entry.profile = shader.profile;
        entry.sourcePath = shader.path;
        entry.outputPath = dxilOutput;
        entry.oldHash = cachedHash;
        entry.newHash = currentHash;
        entry.compileTime = totalTime;

        if (!dxilResult.warningMessage.empty())
        {
            entry.status = LogStatus::STATUS_WARNING;
            entry.message = dxilResult.warningMessage;
        }

        logger.AddEntry(entry);

        std::cout << "[" << (isNew ? "NEW" : "RECOMPILE") << "] " << shader.name
                  << " (" << std::fixed << std::setprecision(3) << totalTime << "s)\n";

        compiled++;
    }

    // Save cache
    if (!opts.dryRun)
    {
        cache.Save(opts.cachePath);
    }

    // Write log
    if (!opts.dryRun)
    {
        logger.WriteToFile(opts.logPath);
        std::cout << "\nLog written to: " << opts.logPath << "\n";
    }

    // Summary
    std::cout << "\n=== Summary ===\n";
    std::cout << "  Compiled: " << compiled << "\n";
    std::cout << "  Skipped:  " << skipped << "\n";
    std::cout << "  Errors:   " << errors << "\n";

    if (errors > 0)
    {
        std::cerr << "\nBuild FAILED with " << errors << " error(s)\n";
        std::cerr << "See " << opts.logPath << " for details\n";
        return 1;
    }

    std::cout << "\nBuild SUCCEEDED\n";
    return 0;
}
