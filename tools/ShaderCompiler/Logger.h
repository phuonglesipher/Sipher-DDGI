/*
 * Shader compilation logger
 * Writes agent-friendly log files
 */

#pragma once

// Undefine Windows macros that conflict with our enum
#ifdef ERROR
#undef ERROR
#endif
#ifdef NEW
#undef NEW
#endif

#include <string>
#include <vector>
#include <fstream>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <iostream>
#include <ctime>

enum class LogStatus
{
    STATUS_OK,
    STATUS_SKIP,
    STATUS_RECOMPILE,
    STATUS_NEW,
    STATUS_WARNING,
    STATUS_ERROR
};

struct LogEntry
{
    LogStatus status;
    std::string shaderName;
    std::string profile;
    std::string sourcePath;
    std::string outputPath;
    std::string message;
    std::vector<std::string> changedFiles;
    std::string oldHash;
    std::string newHash;
    double compileTime = 0.0;
};

class Logger
{
public:
    Logger() = default;

    void SetCompilerVersion(const std::string& version)
    {
        m_compilerVersion = version;
    }

    void SetIncrementalMode(bool incremental)
    {
        m_incrementalMode = incremental;
    }

    void AddEntry(const LogEntry& entry)
    {
        m_entries.push_back(entry);

        switch (entry.status)
        {
        case LogStatus::STATUS_OK:       m_okCount++; break;
        case LogStatus::STATUS_SKIP:     m_skipCount++; break;
        case LogStatus::STATUS_RECOMPILE: m_recompileCount++; break;
        case LogStatus::STATUS_NEW:      m_newCount++; break;
        case LogStatus::STATUS_WARNING:  m_warningCount++; break;
        case LogStatus::STATUS_ERROR:    m_errorCount++; break;
        }
    }

    bool WriteToFile(const std::string& path)
    {
        std::ofstream file(path);
        if (!file.is_open())
        {
            return false;
        }

        // Header
        file << std::string(80, '=') << "\n";
        file << "Shader Compilation Log\n";
        file << "Date: " << GetCurrentDateTime() << "\n";
        file << "DXC Version: " << m_compilerVersion << "\n";
        file << "Mode: " << (m_incrementalMode ? "Incremental (hash-based)" : "Full rebuild") << "\n";
        file << std::string(80, '=') << "\n\n";

        // Entries
        for (const auto& entry : m_entries)
        {
            WriteEntry(file, entry);
            file << "\n";
        }

        // Summary
        file << std::string(80, '=') << "\n";
        file << "Summary: ";

        std::vector<std::string> parts;
        if (m_skipCount > 0) parts.push_back(std::to_string(m_skipCount) + " SKIP");
        if (m_okCount > 0) parts.push_back(std::to_string(m_okCount) + " OK");
        if (m_recompileCount > 0) parts.push_back(std::to_string(m_recompileCount) + " RECOMPILE");
        if (m_newCount > 0) parts.push_back(std::to_string(m_newCount) + " NEW");
        if (m_warningCount > 0) parts.push_back(std::to_string(m_warningCount) + " WARNING");
        if (m_errorCount > 0) parts.push_back(std::to_string(m_errorCount) + " ERROR");

        for (size_t i = 0; i < parts.size(); ++i)
        {
            file << parts[i];
            if (i < parts.size() - 1) file << ", ";
        }
        file << "\n";

        // Total time
        double totalTime = 0.0;
        for (const auto& entry : m_entries)
        {
            totalTime += entry.compileTime;
        }
        file << "Total time: " << std::fixed << std::setprecision(3) << totalTime << "s\n";
        file << std::string(80, '=') << "\n";

        file.close();
        return true;
    }

    // Console output
    void PrintSummary()
    {
        std::cout << "\n";
        std::cout << "Compilation Summary:\n";
        std::cout << "  SKIP:      " << m_skipCount << "\n";
        std::cout << "  OK:        " << m_okCount << "\n";
        std::cout << "  RECOMPILE: " << m_recompileCount << "\n";
        std::cout << "  NEW:       " << m_newCount << "\n";
        std::cout << "  WARNING:   " << m_warningCount << "\n";
        std::cout << "  ERROR:     " << m_errorCount << "\n";
    }

    bool HasErrors() const { return m_errorCount > 0; }
    int GetErrorCount() const { return m_errorCount; }

private:
    std::vector<LogEntry> m_entries;
    std::string m_compilerVersion = "unknown";
    bool m_incrementalMode = false;

    int m_okCount = 0;
    int m_skipCount = 0;
    int m_recompileCount = 0;
    int m_newCount = 0;
    int m_warningCount = 0;
    int m_errorCount = 0;

    std::string GetCurrentDateTime()
    {
        auto now = std::chrono::system_clock::now();
        auto time = std::chrono::system_clock::to_time_t(now);
        std::stringstream ss;
        ss << std::put_time(std::localtime(&time), "%Y-%m-%d %H:%M:%S");
        return ss.str();
    }

    std::string StatusToString(LogStatus status)
    {
        switch (status)
        {
        case LogStatus::STATUS_OK:        return "OK";
        case LogStatus::STATUS_SKIP:      return "SKIP";
        case LogStatus::STATUS_RECOMPILE: return "RECOMPILE";
        case LogStatus::STATUS_NEW:       return "NEW";
        case LogStatus::STATUS_WARNING:   return "WARNING";
        case LogStatus::STATUS_ERROR:     return "ERROR";
        default: return "UNKNOWN";
        }
    }

    void WriteEntry(std::ofstream& file, const LogEntry& entry)
    {
        file << "[" << StatusToString(entry.status) << "] "
             << entry.shaderName << " (" << entry.profile << ")\n";

        file << "     Source: " << entry.sourcePath << "\n";

        if (entry.status == LogStatus::STATUS_SKIP)
        {
            file << "     Status: Up to date (hash match)\n";
            file << "     Hash: " << entry.newHash << "\n";
        }
        else if (entry.status == LogStatus::STATUS_RECOMPILE)
        {
            file << "     Status: Source changed\n";
            file << "     Old hash: " << entry.oldHash << "\n";
            file << "     New hash: " << entry.newHash << "\n";

            if (!entry.changedFiles.empty())
            {
                file << "     Changed files:\n";
                for (const auto& f : entry.changedFiles)
                {
                    file << "       - " << f << "\n";
                }
            }

            file << "     Output: " << entry.outputPath << "\n";
            file << "     Time: " << std::fixed << std::setprecision(3)
                 << entry.compileTime << "s\n";
        }
        else if (entry.status == LogStatus::STATUS_NEW)
        {
            file << "     Status: First compilation\n";
            file << "     Hash: " << entry.newHash << "\n";
            file << "     Output: " << entry.outputPath << "\n";
            file << "     Time: " << std::fixed << std::setprecision(3)
                 << entry.compileTime << "s\n";
        }
        else if (entry.status == LogStatus::STATUS_OK)
        {
            file << "     Output: " << entry.outputPath << "\n";
            file << "     Time: " << std::fixed << std::setprecision(3)
                 << entry.compileTime << "s\n";
        }
        else if (entry.status == LogStatus::STATUS_WARNING)
        {
            file << "     Warning: " << entry.message << "\n";
            file << "     Output: " << entry.outputPath << "\n";
            file << "     Time: " << std::fixed << std::setprecision(3)
                 << entry.compileTime << "s\n";
        }
        else if (entry.status == LogStatus::STATUS_ERROR)
        {
            file << "     Error: " << entry.message << "\n";
        }
    }
};
