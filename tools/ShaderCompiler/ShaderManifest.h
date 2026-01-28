/*
 * Shader manifest parser
 * Reads shaders.json and provides shader definitions
 */

#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <iostream>
#include <regex>
#include <filesystem>

struct ShaderDefinition
{
    std::string name;
    std::string path;
    std::string entryPoint;
    std::string profile;
    std::vector<std::string> defines;
    bool generateSpirv = false;  // Also generate SPIR-V for Vulkan
};

class ShaderManifest
{
public:
    bool Load(const std::string& manifestPath)
    {
        std::filesystem::path absPath = std::filesystem::absolute(manifestPath);
        m_basePath = absPath.parent_path().string();

        std::ifstream file(manifestPath);
        if (!file.is_open())
        {
            std::cerr << "Error: Cannot open manifest file: " << manifestPath << std::endl;
            return false;
        }

        std::stringstream buffer;
        buffer << file.rdbuf();
        std::string content = buffer.str();
        file.close();

        return ParseJson(content);
    }

    const std::vector<ShaderDefinition>& GetShaders() const { return m_shaders; }
    const std::string& GetBasePath() const { return m_basePath; }
    const std::string& GetVersion() const { return m_version; }

private:
    std::vector<ShaderDefinition> m_shaders;
    std::string m_basePath;
    std::string m_version;

    // Simple JSON parser (no external dependencies)
    bool ParseJson(const std::string& json)
    {
        // Extract version
        m_version = ExtractStringValue(json, "version");

        // Find shaders array
        size_t shadersStart = json.find("\"shaders\"");
        if (shadersStart == std::string::npos)
        {
            std::cerr << "Error: No 'shaders' array in manifest" << std::endl;
            return false;
        }

        size_t arrayStart = json.find('[', shadersStart);
        size_t arrayEnd = FindMatchingBracket(json, arrayStart);

        if (arrayStart == std::string::npos || arrayEnd == std::string::npos)
        {
            std::cerr << "Error: Invalid shaders array" << std::endl;
            return false;
        }

        std::string arrayContent = json.substr(arrayStart + 1, arrayEnd - arrayStart - 1);

        // Parse each shader object
        size_t pos = 0;
        while (pos < arrayContent.size())
        {
            size_t objStart = arrayContent.find('{', pos);
            if (objStart == std::string::npos) break;

            size_t objEnd = FindMatchingBrace(arrayContent, objStart);
            if (objEnd == std::string::npos) break;

            std::string objContent = arrayContent.substr(objStart, objEnd - objStart + 1);

            ShaderDefinition shader;
            shader.name = ExtractStringValue(objContent, "name");
            shader.path = ExtractStringValue(objContent, "path");
            shader.entryPoint = ExtractStringValue(objContent, "entry");
            shader.profile = ExtractStringValue(objContent, "profile");
            shader.generateSpirv = ExtractBoolValue(objContent, "spirv");
            shader.defines = ExtractStringArray(objContent, "defines");

            if (!shader.name.empty() && !shader.path.empty())
            {
                m_shaders.push_back(shader);
            }

            pos = objEnd + 1;
        }

        return !m_shaders.empty();
    }

    std::string ExtractStringValue(const std::string& json, const std::string& key)
    {
        std::string pattern = "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"";
        std::regex re(pattern);
        std::smatch match;

        if (std::regex_search(json, match, re))
        {
            return match[1].str();
        }
        return "";
    }

    bool ExtractBoolValue(const std::string& json, const std::string& key)
    {
        std::string pattern = "\"" + key + "\"\\s*:\\s*(true|false)";
        std::regex re(pattern);
        std::smatch match;

        if (std::regex_search(json, match, re))
        {
            return match[1].str() == "true";
        }
        return false;
    }

    std::vector<std::string> ExtractStringArray(const std::string& json, const std::string& key)
    {
        std::vector<std::string> result;

        std::string pattern = "\"" + key + "\"\\s*:\\s*\\[([^\\]]*)\\]";
        std::regex re(pattern);
        std::smatch match;

        if (std::regex_search(json, match, re))
        {
            std::string arrayContent = match[1].str();

            std::regex strRe("\"([^\"]*)\"");
            auto begin = std::sregex_iterator(arrayContent.begin(), arrayContent.end(), strRe);
            auto end = std::sregex_iterator();

            for (auto it = begin; it != end; ++it)
            {
                result.push_back((*it)[1].str());
            }
        }

        return result;
    }

    size_t FindMatchingBracket(const std::string& str, size_t start)
    {
        if (start >= str.size() || str[start] != '[') return std::string::npos;

        int depth = 1;
        for (size_t i = start + 1; i < str.size(); ++i)
        {
            if (str[i] == '[') depth++;
            else if (str[i] == ']')
            {
                depth--;
                if (depth == 0) return i;
            }
        }
        return std::string::npos;
    }

    size_t FindMatchingBrace(const std::string& str, size_t start)
    {
        if (start >= str.size() || str[start] != '{') return std::string::npos;

        int depth = 1;
        for (size_t i = start + 1; i < str.size(); ++i)
        {
            if (str[i] == '{') depth++;
            else if (str[i] == '}')
            {
                depth--;
                if (depth == 0) return i;
            }
        }
        return std::string::npos;
    }
};
