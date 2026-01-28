/*
 * Hash cache for incremental shader compilation
 * Stores shader hashes to detect changes
 */

#pragma once

#include <string>
#include <map>
#include <vector>
#include <fstream>
#include <sstream>
#include <regex>
#include <filesystem>

struct ShaderCacheEntry
{
    std::string hash;
    std::string sourcePath;
    std::vector<std::string> includes;
    std::vector<std::string> defines;
    std::string outputDxil;
    std::string outputSpirv;
    std::string lastCompiled;
};

class HashCache
{
public:
    HashCache() = default;

    void SetCompilerVersion(const std::string& version)
    {
        m_compilerVersion = version;
    }

    bool Load(const std::string& cachePath)
    {
        m_cachePath = cachePath;
        m_entries.clear();

        std::ifstream file(cachePath);
        if (!file.is_open())
        {
            return false;  // Cache doesn't exist yet
        }

        std::stringstream buffer;
        buffer << file.rdbuf();
        std::string content = buffer.str();
        file.close();

        return ParseJson(content);
    }

    bool Save(const std::string& cachePath)
    {
        std::ofstream file(cachePath);
        if (!file.is_open())
        {
            return false;
        }

        file << "{\n";
        file << "  \"version\": \"1.0\",\n";
        file << "  \"compiler_version\": \"" << m_compilerVersion << "\",\n";
        file << "  \"entries\": {\n";

        size_t count = 0;
        for (const auto& [name, entry] : m_entries)
        {
            file << "    \"" << name << "\": {\n";
            file << "      \"hash\": \"" << entry.hash << "\",\n";
            file << "      \"source\": \"" << EscapePath(entry.sourcePath) << "\",\n";

            // Includes array
            file << "      \"includes\": [";
            for (size_t i = 0; i < entry.includes.size(); ++i)
            {
                file << "\"" << EscapePath(entry.includes[i]) << "\"";
                if (i < entry.includes.size() - 1) file << ", ";
            }
            file << "],\n";

            // Defines array
            file << "      \"defines\": [";
            for (size_t i = 0; i < entry.defines.size(); ++i)
            {
                file << "\"" << entry.defines[i] << "\"";
                if (i < entry.defines.size() - 1) file << ", ";
            }
            file << "],\n";

            file << "      \"output_dxil\": \"" << EscapePath(entry.outputDxil) << "\",\n";
            file << "      \"output_spirv\": \"" << EscapePath(entry.outputSpirv) << "\",\n";
            file << "      \"last_compiled\": \"" << entry.lastCompiled << "\"\n";
            file << "    }";

            if (++count < m_entries.size()) file << ",";
            file << "\n";
        }

        file << "  }\n";
        file << "}\n";

        file.close();
        return true;
    }

    bool IsUpToDate(const std::string& shaderName, const std::string& currentHash)
    {
        auto it = m_entries.find(shaderName);
        if (it == m_entries.end())
        {
            return false;  // Not in cache
        }

        // Check if hash matches
        if (it->second.hash != currentHash)
        {
            return false;  // Hash changed
        }

        // Check if output files exist
        if (!it->second.outputDxil.empty() && !std::filesystem::exists(it->second.outputDxil))
        {
            return false;  // Output missing
        }

        return true;
    }

    std::string GetCachedHash(const std::string& shaderName)
    {
        auto it = m_entries.find(shaderName);
        if (it != m_entries.end())
        {
            return it->second.hash;
        }
        return "";
    }

    bool HasEntry(const std::string& shaderName)
    {
        return m_entries.find(shaderName) != m_entries.end();
    }

    void UpdateEntry(const std::string& shaderName, const ShaderCacheEntry& entry)
    {
        m_entries[shaderName] = entry;
    }

    void RemoveEntry(const std::string& shaderName)
    {
        m_entries.erase(shaderName);
    }

    bool CompilerVersionChanged(const std::string& currentVersion)
    {
        return m_compilerVersion != currentVersion && !m_compilerVersion.empty();
    }

private:
    std::map<std::string, ShaderCacheEntry> m_entries;
    std::string m_cachePath;
    std::string m_compilerVersion;

    std::string EscapePath(const std::string& path)
    {
        std::string result;
        for (char c : path)
        {
            if (c == '\\')
            {
                result += "\\\\";
            }
            else
            {
                result += c;
            }
        }
        return result;
    }

    bool ParseJson(const std::string& json)
    {
        // Extract compiler version
        m_compilerVersion = ExtractStringValue(json, "compiler_version");

        // Find entries object
        size_t entriesStart = json.find("\"entries\"");
        if (entriesStart == std::string::npos)
        {
            return false;
        }

        size_t objStart = json.find('{', entriesStart);
        size_t objEnd = FindMatchingBrace(json, objStart);

        if (objStart == std::string::npos || objEnd == std::string::npos)
        {
            return false;
        }

        std::string entriesContent = json.substr(objStart + 1, objEnd - objStart - 1);

        // Parse each shader entry
        std::regex shaderRegex("\"([^\"]+)\"\\s*:\\s*\\{");
        auto matchBegin = std::sregex_iterator(entriesContent.begin(), entriesContent.end(), shaderRegex);
        auto matchEnd = std::sregex_iterator();

        for (auto it = matchBegin; it != matchEnd; ++it)
        {
            std::string shaderName = (*it)[1].str();
            size_t entryStart = it->position() + it->length() - 1;
            size_t entryEnd = FindMatchingBrace(entriesContent, entryStart);

            if (entryEnd == std::string::npos) continue;

            std::string entryContent = entriesContent.substr(entryStart, entryEnd - entryStart + 1);

            ShaderCacheEntry entry;
            entry.hash = ExtractStringValue(entryContent, "hash");
            entry.sourcePath = ExtractStringValue(entryContent, "source");
            entry.outputDxil = ExtractStringValue(entryContent, "output_dxil");
            entry.outputSpirv = ExtractStringValue(entryContent, "output_spirv");
            entry.lastCompiled = ExtractStringValue(entryContent, "last_compiled");
            entry.includes = ExtractStringArray(entryContent, "includes");
            entry.defines = ExtractStringArray(entryContent, "defines");

            m_entries[shaderName] = entry;
        }

        return true;
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
