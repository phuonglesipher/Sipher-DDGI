/*
 * Simple hash utilities for shader caching
 * Uses xxHash-style algorithm for speed
 */

#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <iomanip>

namespace Hash
{
    // FNV-1a 64-bit hash constants
    constexpr uint64_t FNV_OFFSET_BASIS = 14695981039346656037ULL;
    constexpr uint64_t FNV_PRIME = 1099511628211ULL;

    // Simple FNV-1a hash for strings
    inline uint64_t FNV1a(const std::string& data)
    {
        uint64_t hash = FNV_OFFSET_BASIS;
        for (char c : data)
        {
            hash ^= static_cast<uint64_t>(static_cast<unsigned char>(c));
            hash *= FNV_PRIME;
        }
        return hash;
    }

    // Hash combine (for multiple inputs)
    inline uint64_t Combine(uint64_t h1, uint64_t h2)
    {
        return h1 ^ (h2 + 0x9e3779b9 + (h1 << 6) + (h1 >> 2));
    }

    // Convert hash to hex string
    inline std::string ToHexString(uint64_t hash)
    {
        std::ostringstream oss;
        oss << std::hex << std::setfill('0') << std::setw(16) << hash;
        return oss.str();
    }

    // Read file contents
    inline std::string ReadFile(const std::string& path)
    {
        std::ifstream file(path, std::ios::binary);
        if (!file.is_open())
        {
            return "";
        }

        std::stringstream buffer;
        buffer << file.rdbuf();
        return buffer.str();
    }

    // Compute hash of a file
    inline uint64_t HashFile(const std::string& path)
    {
        std::string content = ReadFile(path);
        return FNV1a(content);
    }

    // Compute combined hash of multiple files
    inline uint64_t HashFiles(const std::vector<std::string>& paths)
    {
        uint64_t combined = FNV_OFFSET_BASIS;
        for (const auto& path : paths)
        {
            uint64_t fileHash = HashFile(path);
            combined = Combine(combined, fileHash);
        }
        return combined;
    }

    // Compute hash of shader with all dependencies
    inline std::string ComputeShaderHash(
        const std::string& sourcePath,
        const std::vector<std::string>& includePaths,
        const std::vector<std::string>& defines,
        const std::string& profile,
        const std::string& entryPoint)
    {
        uint64_t hash = FNV_OFFSET_BASIS;

        // Hash source file
        hash = Combine(hash, HashFile(sourcePath));

        // Hash all include files (sorted for determinism)
        std::vector<std::string> sortedIncludes = includePaths;
        std::sort(sortedIncludes.begin(), sortedIncludes.end());
        for (const auto& inc : sortedIncludes)
        {
            hash = Combine(hash, HashFile(inc));
        }

        // Hash defines (sorted)
        std::vector<std::string> sortedDefines = defines;
        std::sort(sortedDefines.begin(), sortedDefines.end());
        for (const auto& def : sortedDefines)
        {
            hash = Combine(hash, FNV1a(def));
        }

        // Hash profile and entry point
        hash = Combine(hash, FNV1a(profile));
        hash = Combine(hash, FNV1a(entryPoint));

        return ToHexString(hash);
    }

} // namespace Hash
