/*
 * DXC Shader Compiler wrapper
 * Handles DXIL and SPIR-V compilation
 */

#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <filesystem>

#ifdef _WIN32
#include <windows.h>
#include <dxcapi.h>
#else
#include <dlfcn.h>
#include "dxc/dxcapi.h"
#endif

namespace fs = std::filesystem;

struct CompileResult
{
    bool success = false;
    std::string errorMessage;
    std::string warningMessage;
    std::vector<uint8_t> bytecode;
    double compileTime = 0.0;
};

class Compiler
{
public:
    Compiler() = default;
    ~Compiler() { Cleanup(); }

    bool Initialize(const std::string& projectRoot = "")
    {
        // Load DXC DLL
#ifdef _WIN32
        // Try loading from common locations
        std::vector<std::string> searchPaths = {
            "",  // Current directory / PATH
            projectRoot + "/external/dxc/bin/x64/",
            projectRoot + "/../external/dxc/bin/x64/",
            projectRoot + "/../../external/dxc/bin/x64/"
        };

        for (const auto& path : searchPaths)
        {
            std::string dllPath = path + "dxcompiler.dll";
            m_dxcDll = LoadLibraryA(dllPath.c_str());
            if (m_dxcDll)
            {
                m_dxcPath = path;
                break;
            }
        }

        if (!m_dxcDll)
        {
            m_lastError = "Failed to load dxcompiler.dll. Searched: ";
            for (const auto& p : searchPaths)
            {
                m_lastError += (p.empty() ? "PATH" : p) + ", ";
            }
            return false;
        }

        m_dxcCreateInstance = (DxcCreateInstanceProc)GetProcAddress(m_dxcDll, "DxcCreateInstance");
#else
        m_dxcDll = dlopen("libdxcompiler.so", RTLD_LAZY);
        if (!m_dxcDll)
        {
            m_lastError = "Failed to load libdxcompiler.so";
            return false;
        }

        m_dxcCreateInstance = (DxcCreateInstanceProc)dlsym(m_dxcDll, "DxcCreateInstance");
#endif

        if (!m_dxcCreateInstance)
        {
            m_lastError = "Failed to get DxcCreateInstance";
            return false;
        }

        // Create DXC instances
        if (FAILED(m_dxcCreateInstance(CLSID_DxcUtils, IID_PPV_ARGS(&m_utils))))
        {
            m_lastError = "Failed to create DxcUtils";
            return false;
        }

        if (FAILED(m_dxcCreateInstance(CLSID_DxcCompiler, IID_PPV_ARGS(&m_compiler))))
        {
            m_lastError = "Failed to create DxcCompiler";
            return false;
        }

        if (FAILED(m_utils->CreateDefaultIncludeHandler(&m_includeHandler)))
        {
            m_lastError = "Failed to create include handler";
            return false;
        }

        m_initialized = true;
        return true;
    }

    void Cleanup()
    {
        if (m_includeHandler) { m_includeHandler->Release(); m_includeHandler = nullptr; }
        if (m_compiler) { m_compiler->Release(); m_compiler = nullptr; }
        if (m_utils) { m_utils->Release(); m_utils = nullptr; }

#ifdef _WIN32
        if (m_dxcDll) { FreeLibrary(m_dxcDll); m_dxcDll = nullptr; }
#else
        if (m_dxcDll) { dlclose(m_dxcDll); m_dxcDll = nullptr; }
#endif
    }

    CompileResult CompileDXIL(
        const std::string& sourcePath,
        const std::string& entryPoint,
        const std::string& profile,
        const std::vector<std::string>& defines,
        const std::vector<std::string>& includeDirs)
    {
        return CompileInternal(sourcePath, entryPoint, profile, defines, includeDirs, false);
    }

    CompileResult CompileSPIRV(
        const std::string& sourcePath,
        const std::string& entryPoint,
        const std::string& profile,
        const std::vector<std::string>& defines,
        const std::vector<std::string>& includeDirs)
    {
        return CompileInternal(sourcePath, entryPoint, profile, defines, includeDirs, true);
    }

    bool SaveBytecode(const std::vector<uint8_t>& bytecode, const std::string& outputPath)
    {
        // Create output directory if needed
        fs::path outPath(outputPath);
        fs::create_directories(outPath.parent_path());

        std::ofstream file(outputPath, std::ios::binary);
        if (!file.is_open())
        {
            return false;
        }

        file.write(reinterpret_cast<const char*>(bytecode.data()), bytecode.size());
        file.close();
        return true;
    }

    std::string GetVersion() const { return "1.7.2308"; }  // Hardcoded for now
    std::string GetLastError() const { return m_lastError; }

private:
    bool m_initialized = false;
    std::string m_lastError;
    std::string m_dxcPath;

#ifdef _WIN32
    HMODULE m_dxcDll = nullptr;
#else
    void* m_dxcDll = nullptr;
#endif

    typedef HRESULT(__stdcall* DxcCreateInstanceProc)(REFCLSID, REFIID, void**);
    DxcCreateInstanceProc m_dxcCreateInstance = nullptr;

    IDxcUtils* m_utils = nullptr;
    IDxcCompiler3* m_compiler = nullptr;
    IDxcIncludeHandler* m_includeHandler = nullptr;

    CompileResult CompileInternal(
        const std::string& sourcePath,
        const std::string& entryPoint,
        const std::string& profile,
        const std::vector<std::string>& defines,
        const std::vector<std::string>& includeDirs,
        bool spirv)
    {
        CompileResult result;

        auto startTime = std::chrono::high_resolution_clock::now();

        if (!m_initialized)
        {
            result.errorMessage = "Compiler not initialized";
            return result;
        }

        // Load source file
        std::wstring wSourcePath = ToWideString(sourcePath);
        IDxcBlobEncoding* sourceBlob = nullptr;

        if (FAILED(m_utils->LoadFile(wSourcePath.c_str(), nullptr, &sourceBlob)))
        {
            result.errorMessage = "Failed to load source file: " + sourcePath;
            return result;
        }

        DxcBuffer sourceBuffer;
        sourceBuffer.Ptr = sourceBlob->GetBufferPointer();
        sourceBuffer.Size = sourceBlob->GetBufferSize();
        sourceBuffer.Encoding = DXC_CP_ACP;

        // Build arguments using BuildArguments helper
        std::vector<LPCWSTR> extraArgs;
        std::vector<std::wstring> argStorage;  // Keep wstrings alive

        // Include directories (as -I <path> in arguments)
        for (const auto& inc : includeDirs)
        {
            std::wstring incArg = L"-I" + ToWideString(inc);
            argStorage.push_back(incArg);
            extraArgs.push_back(argStorage.back().c_str());
        }

        // SPIR-V specific
        if (spirv)
        {
            extraArgs.push_back(L"-spirv");
            extraArgs.push_back(L"-fspv-target-env=vulkan1.2");
        }

        // Build defines array - store all strings first, then build pointers
        std::vector<std::pair<std::wstring, std::wstring>> defineNameValue;

        // HLSL define
        defineNameValue.push_back({L"HLSL", L"1"});

        for (const auto& def : defines)
        {
            size_t eq = def.find('=');
            if (eq != std::string::npos)
            {
                defineNameValue.push_back({
                    ToWideString(def.substr(0, eq)),
                    ToWideString(def.substr(eq + 1))
                });
            }
            else
            {
                defineNameValue.push_back({ToWideString(def), L""});
            }
        }

        // Now build DxcDefine array from stored strings
        std::vector<DxcDefine> dxcDefines;
        for (const auto& nv : defineNameValue)
        {
            DxcDefine d;
            d.Name = nv.first.c_str();
            d.Value = nv.second.empty() ? nullptr : nv.second.c_str();
            dxcDefines.push_back(d);
        }

        // Build arguments using DXC helper
        std::wstring wFilePath = ToWideString(sourcePath);
        std::wstring wEntryPoint = ToWideString(entryPoint);
        std::wstring wProfile = ToWideString(profile);

        IDxcCompilerArgs* args = nullptr;
        HRESULT buildResult = m_utils->BuildArguments(
            wFilePath.c_str(),
            wEntryPoint.c_str(),
            wProfile.c_str(),
            extraArgs.data(),
            static_cast<UINT>(extraArgs.size()),
            dxcDefines.data(),
            static_cast<UINT>(dxcDefines.size()),
            &args
        );

        if (FAILED(buildResult))
        {
            result.errorMessage = "Failed to build arguments: " + std::to_string(buildResult);
            sourceBlob->Release();
            return result;
        }

        // Compile
        IDxcResult* compileResult = nullptr;
        HRESULT hr = m_compiler->Compile(
            &sourceBuffer,
            args->GetArguments(),
            args->GetCount(),
            m_includeHandler,
            IID_PPV_ARGS(&compileResult)
        );

        args->Release();

        sourceBlob->Release();

        if (FAILED(hr))
        {
            result.errorMessage = "Compilation failed with HRESULT: " + std::to_string(hr);
            return result;
        }

        // Get errors
        IDxcBlobUtf8* errors = nullptr;
        compileResult->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(&errors), nullptr);

        if (errors && errors->GetStringLength() > 0)
        {
            std::string errorStr(errors->GetStringPointer(), errors->GetStringLength());

            // Check if it's a warning or error
            HRESULT status;
            compileResult->GetStatus(&status);

            if (FAILED(status))
            {
                result.errorMessage = errorStr;
                errors->Release();
                compileResult->Release();
                return result;
            }
            else
            {
                result.warningMessage = errorStr;
            }

            errors->Release();
        }

        // Get bytecode
        IDxcBlob* bytecode = nullptr;
        IDxcBlobUtf16* shaderName = nullptr;
        compileResult->GetOutput(DXC_OUT_OBJECT, IID_PPV_ARGS(&bytecode), &shaderName);

        if (bytecode)
        {
            result.bytecode.resize(bytecode->GetBufferSize());
            memcpy(result.bytecode.data(), bytecode->GetBufferPointer(), bytecode->GetBufferSize());
            bytecode->Release();
        }

        if (shaderName) shaderName->Release();
        compileResult->Release();

        auto endTime = std::chrono::high_resolution_clock::now();
        result.compileTime = std::chrono::duration<double>(endTime - startTime).count();

        result.success = !result.bytecode.empty();
        return result;
    }

    std::wstring ToWideString(const std::string& str)
    {
        if (str.empty()) return L"";

#ifdef _WIN32
        int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
        std::wstring result(size - 1, 0);
        MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &result[0], size);
        return result;
#else
        std::wstring result(str.begin(), str.end());
        return result;
#endif
    }
};
