/*
 * Include dependency parser for HLSL shaders
 * Recursively parses #include directives
 */

#pragma once

#include <string>
#include <vector>
#include <set>
#include <regex>
#include <fstream>
#include <sstream>
#include <filesystem>

namespace fs = std::filesystem;

class IncludeParser
{
public:
    IncludeParser() = default;

    // Set base include directories for resolving paths
    void AddIncludeDirectory(const std::string& dir)
    {
        m_includeDirs.push_back(dir);
    }

    // Parse all #include dependencies recursively
    std::vector<std::string> ParseDependencies(const std::string& shaderPath)
    {
        m_dependencies.clear();
        m_visited.clear();

        fs::path absPath = fs::absolute(shaderPath);
        ParseRecursive(absPath.string());

        // Convert set to vector (already sorted)
        std::vector<std::string> result(m_dependencies.begin(), m_dependencies.end());
        return result;
    }

private:
    std::vector<std::string> m_includeDirs;
    std::set<std::string> m_dependencies;
    std::set<std::string> m_visited;

    void ParseRecursive(const std::string& filePath)
    {
        // Normalize path
        fs::path normalizedPath = fs::absolute(filePath);
        std::string pathStr = normalizedPath.string();

        // Skip if already visited (prevent infinite loops)
        if (m_visited.count(pathStr))
        {
            return;
        }
        m_visited.insert(pathStr);

        // Read file content
        std::ifstream file(pathStr);
        if (!file.is_open())
        {
            return;
        }

        std::string content((std::istreambuf_iterator<char>(file)),
                            std::istreambuf_iterator<char>());
        file.close();

        // Regex for #include "path" or #include <path>
        std::regex includeRegex(R"(#\s*include\s*[<"]([^>"]+)[>"])");

        auto matchBegin = std::sregex_iterator(content.begin(), content.end(), includeRegex);
        auto matchEnd = std::sregex_iterator();

        fs::path baseDir = normalizedPath.parent_path();

        for (auto it = matchBegin; it != matchEnd; ++it)
        {
            std::string includePath = (*it)[1].str();

            // Try to resolve the include path
            std::string resolvedPath = ResolvePath(baseDir.string(), includePath);

            if (!resolvedPath.empty() && fs::exists(resolvedPath))
            {
                m_dependencies.insert(resolvedPath);
                ParseRecursive(resolvedPath);
            }
        }
    }

    std::string ResolvePath(const std::string& baseDir, const std::string& includePath)
    {
        // Try relative to current file first
        fs::path relativePath = fs::path(baseDir) / includePath;
        if (fs::exists(relativePath))
        {
            return fs::absolute(relativePath).string();
        }

        // Try each include directory
        for (const auto& incDir : m_includeDirs)
        {
            fs::path incPath = fs::path(incDir) / includePath;
            if (fs::exists(incPath))
            {
                return fs::absolute(incPath).string();
            }
        }

        // Try common relative paths
        std::vector<std::string> commonPrefixes = {
            "../include/",
            "include/",
            "../",
            ""
        };

        for (const auto& prefix : commonPrefixes)
        {
            fs::path tryPath = fs::path(baseDir) / prefix / includePath;
            if (fs::exists(tryPath))
            {
                return fs::absolute(tryPath).string();
            }
        }

        return "";
    }
};
