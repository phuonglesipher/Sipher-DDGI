/*
 * Application Logger for Claude Code Agent Debugging
 *
 * Features:
 * - Structured logging with timestamps and severity levels
 * - Crash/exception handling with diagnostics
 * - D3D12 device removed reason logging
 * - Shader compilation error capture
 * - Agent-friendly log format for easy parsing
 */

#pragma once

#include <string>
#include <fstream>
#include <sstream>
#include <chrono>
#include <iomanip>
#include <mutex>
#include <vector>

#ifdef _WIN32
// Save and undefine Windows macros that conflict with our enum
#pragma push_macro("ERROR")
#undef ERROR
#include <windows.h>
#include <dbghelp.h>
#include <d3d12.h>
#pragma comment(lib, "dbghelp.lib")
#endif

namespace AppLog
{
    enum class Level
    {
        LOG_DEBUG,
        LOG_INFO,
        LOG_WARNING,
        LOG_ERROR,
        LOG_FATAL
    };

    struct LogEntry
    {
        std::string timestamp;
        Level level;
        std::string category;
        std::string message;
        std::string file;
        int line;
    };

    class Logger
    {
    public:
        static Logger& Instance()
        {
            static Logger instance;
            return instance;
        }

        bool Initialize(const std::string& logPath = "app_log.txt")
        {
            std::lock_guard<std::mutex> lock(m_mutex);

            m_logPath = logPath;
            m_file.open(logPath, std::ios::out | std::ios::trunc);
            if (!m_file.is_open()) return false;

            // Write header
            m_file << "================================================================================\n";
            m_file << "Application Log - Sipher-DDGI Test Harness\n";
            m_file << "Started: " << GetTimestamp() << "\n";
            m_file << "================================================================================\n\n";
            m_file << "FORMAT: [TIMESTAMP] [LEVEL] [CATEGORY] MESSAGE\n";
            m_file << "================================================================================\n\n";
            m_file.flush();

            m_initialized = true;

#ifdef _WIN32
            // Install crash handlers
            SetUnhandledExceptionFilter(CrashHandler);

            // Initialize symbol handler for stack traces
            SymInitialize(GetCurrentProcess(), NULL, TRUE);
#endif

            return true;
        }

        void Shutdown()
        {
            std::lock_guard<std::mutex> lock(m_mutex);

            if (m_file.is_open())
            {
                m_file << "\n================================================================================\n";
                m_file << "Application shutdown: " << GetTimestamp() << "\n";
                m_file << "Total errors: " << m_errorCount << "\n";
                m_file << "Total warnings: " << m_warningCount << "\n";
                m_file << "================================================================================\n";
                m_file.close();
            }

#ifdef _WIN32
            SymCleanup(GetCurrentProcess());
#endif
        }

        void Log(Level level, const std::string& category, const std::string& message,
                 const char* file = nullptr, int line = 0)
        {
            std::lock_guard<std::mutex> lock(m_mutex);

            if (!m_initialized) return;

            // Track counts
            if (level == Level::LOG_ERROR || level == Level::LOG_FATAL) m_errorCount++;
            if (level == Level::LOG_WARNING) m_warningCount++;

            // Format log entry
            std::stringstream ss;
            ss << "[" << GetTimestamp() << "] ";
            ss << "[" << LevelToString(level) << "] ";
            ss << "[" << category << "] ";
            ss << message;

            if (file && line > 0)
            {
                ss << " (" << ExtractFilename(file) << ":" << line << ")";
            }

            ss << "\n";

            m_file << ss.str();
            m_file.flush();  // Always flush for crash safety

            // Store recent entries for crash dump
            LogEntry entry;
            entry.timestamp = GetTimestamp();
            entry.level = level;
            entry.category = category;
            entry.message = message;
            entry.file = file ? file : "";
            entry.line = line;

            m_recentEntries.push_back(entry);
            if (m_recentEntries.size() > 100)
            {
                m_recentEntries.erase(m_recentEntries.begin());
            }
        }

        void LogShaderError(const std::string& shaderName, const std::string& errorMessage)
        {
            std::lock_guard<std::mutex> lock(m_mutex);

            if (!m_initialized) return;

            m_file << "\n";
            m_file << "================================================================================\n";
            m_file << "[SHADER_ERROR] " << shaderName << "\n";
            m_file << "--------------------------------------------------------------------------------\n";
            m_file << errorMessage << "\n";
            m_file << "================================================================================\n\n";
            m_file.flush();

            m_errorCount++;
        }

#ifdef _WIN32
        void LogD3D12DeviceRemoved(ID3D12Device* device)
        {
            std::lock_guard<std::mutex> lock(m_mutex);

            if (!m_initialized || !device) return;

            HRESULT reason = device->GetDeviceRemovedReason();

            m_file << "\n";
            m_file << "================================================================================\n";
            m_file << "[D3D12_DEVICE_REMOVED]\n";
            m_file << "Timestamp: " << GetTimestamp() << "\n";
            m_file << "Reason: " << D3D12DeviceRemovedReasonToString(reason) << "\n";
            m_file << "HRESULT: 0x" << std::hex << reason << std::dec << "\n";
            m_file << "--------------------------------------------------------------------------------\n";
            m_file << "Recent Log Entries:\n";

            for (const auto& entry : m_recentEntries)
            {
                m_file << "  [" << entry.timestamp << "] [" << LevelToString(entry.level) << "] ";
                m_file << entry.category << ": " << entry.message << "\n";
            }

            m_file << "================================================================================\n\n";
            m_file.flush();
        }

        static LONG WINAPI CrashHandler(EXCEPTION_POINTERS* exceptionInfo)
        {
            Logger& logger = Instance();

            std::lock_guard<std::mutex> lock(logger.m_mutex);

            if (!logger.m_initialized) return EXCEPTION_CONTINUE_SEARCH;

            logger.m_file << "\n";
            logger.m_file << "********************************************************************************\n";
            logger.m_file << "[CRASH] APPLICATION CRASH DETECTED\n";
            logger.m_file << "********************************************************************************\n";
            logger.m_file << "Timestamp: " << logger.GetTimestamp() << "\n";
            logger.m_file << "Exception Code: 0x" << std::hex << exceptionInfo->ExceptionRecord->ExceptionCode << std::dec << "\n";
            logger.m_file << "Exception Address: 0x" << std::hex << (uintptr_t)exceptionInfo->ExceptionRecord->ExceptionAddress << std::dec << "\n";
            logger.m_file << "Exception Type: " << logger.ExceptionCodeToString(exceptionInfo->ExceptionRecord->ExceptionCode) << "\n";
            logger.m_file << "--------------------------------------------------------------------------------\n";

            // Stack trace
            logger.m_file << "Stack Trace:\n";
            logger.CaptureStackTrace(exceptionInfo->ContextRecord);

            logger.m_file << "--------------------------------------------------------------------------------\n";
            logger.m_file << "Recent Log Entries (last 100):\n";

            for (const auto& entry : logger.m_recentEntries)
            {
                logger.m_file << "  [" << entry.timestamp << "] [" << logger.LevelToString(entry.level) << "] ";
                logger.m_file << "[" << entry.category << "] " << entry.message;
                if (!entry.file.empty())
                {
                    logger.m_file << " (" << entry.file << ":" << entry.line << ")";
                }
                logger.m_file << "\n";
            }

            logger.m_file << "********************************************************************************\n";
            logger.m_file.flush();
            logger.m_file.close();

            return EXCEPTION_CONTINUE_SEARCH;
        }

        void CaptureStackTrace(CONTEXT* context)
        {
            HANDLE process = GetCurrentProcess();
            HANDLE thread = GetCurrentThread();

            STACKFRAME64 stackFrame = {};
            stackFrame.AddrPC.Mode = AddrModeFlat;
            stackFrame.AddrFrame.Mode = AddrModeFlat;
            stackFrame.AddrStack.Mode = AddrModeFlat;

#ifdef _M_X64
            DWORD machineType = IMAGE_FILE_MACHINE_AMD64;
            stackFrame.AddrPC.Offset = context->Rip;
            stackFrame.AddrFrame.Offset = context->Rbp;
            stackFrame.AddrStack.Offset = context->Rsp;
#else
            DWORD machineType = IMAGE_FILE_MACHINE_I386;
            stackFrame.AddrPC.Offset = context->Eip;
            stackFrame.AddrFrame.Offset = context->Ebp;
            stackFrame.AddrStack.Offset = context->Esp;
#endif

            char symbolBuffer[sizeof(SYMBOL_INFO) + MAX_SYM_NAME * sizeof(TCHAR)];
            PSYMBOL_INFO symbol = (PSYMBOL_INFO)symbolBuffer;
            symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
            symbol->MaxNameLen = MAX_SYM_NAME;

            IMAGEHLP_LINE64 line = {};
            line.SizeOfStruct = sizeof(IMAGEHLP_LINE64);

            int frameCount = 0;
            while (StackWalk64(machineType, process, thread, &stackFrame, context,
                              NULL, SymFunctionTableAccess64, SymGetModuleBase64, NULL))
            {
                if (stackFrame.AddrPC.Offset == 0) break;
                if (frameCount++ > 50) break;  // Limit stack depth

                DWORD64 displacement = 0;
                DWORD lineDisplacement = 0;

                m_file << "  [" << frameCount << "] 0x" << std::hex << stackFrame.AddrPC.Offset << std::dec;

                if (SymFromAddr(process, stackFrame.AddrPC.Offset, &displacement, symbol))
                {
                    m_file << " " << symbol->Name;
                }

                if (SymGetLineFromAddr64(process, stackFrame.AddrPC.Offset, &lineDisplacement, &line))
                {
                    m_file << " (" << line.FileName << ":" << line.LineNumber << ")";
                }

                m_file << "\n";
            }
        }

        std::string D3D12DeviceRemovedReasonToString(HRESULT reason)
        {
            switch (reason)
            {
            case DXGI_ERROR_DEVICE_HUNG:
                return "DXGI_ERROR_DEVICE_HUNG - GPU took too long to execute commands";
            case DXGI_ERROR_DEVICE_REMOVED:
                return "DXGI_ERROR_DEVICE_REMOVED - GPU was physically removed or driver was updated";
            case DXGI_ERROR_DEVICE_RESET:
                return "DXGI_ERROR_DEVICE_RESET - GPU reset due to badly formed command";
            case DXGI_ERROR_DRIVER_INTERNAL_ERROR:
                return "DXGI_ERROR_DRIVER_INTERNAL_ERROR - Driver bug or hardware failure";
            case DXGI_ERROR_INVALID_CALL:
                return "DXGI_ERROR_INVALID_CALL - Invalid API call";
            case S_OK:
                return "S_OK - No error (unexpected in this context)";
            default:
                return "Unknown error code";
            }
        }

        std::string ExceptionCodeToString(DWORD code)
        {
            switch (code)
            {
            case EXCEPTION_ACCESS_VIOLATION: return "ACCESS_VIOLATION - Invalid memory access";
            case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "ARRAY_BOUNDS_EXCEEDED";
            case EXCEPTION_BREAKPOINT: return "BREAKPOINT";
            case EXCEPTION_DATATYPE_MISALIGNMENT: return "DATATYPE_MISALIGNMENT";
            case EXCEPTION_FLT_DENORMAL_OPERAND: return "FLT_DENORMAL_OPERAND";
            case EXCEPTION_FLT_DIVIDE_BY_ZERO: return "FLT_DIVIDE_BY_ZERO";
            case EXCEPTION_FLT_INEXACT_RESULT: return "FLT_INEXACT_RESULT";
            case EXCEPTION_FLT_INVALID_OPERATION: return "FLT_INVALID_OPERATION";
            case EXCEPTION_FLT_OVERFLOW: return "FLT_OVERFLOW";
            case EXCEPTION_FLT_STACK_CHECK: return "FLT_STACK_CHECK";
            case EXCEPTION_FLT_UNDERFLOW: return "FLT_UNDERFLOW";
            case EXCEPTION_ILLEGAL_INSTRUCTION: return "ILLEGAL_INSTRUCTION";
            case EXCEPTION_IN_PAGE_ERROR: return "IN_PAGE_ERROR";
            case EXCEPTION_INT_DIVIDE_BY_ZERO: return "INT_DIVIDE_BY_ZERO";
            case EXCEPTION_INT_OVERFLOW: return "INT_OVERFLOW";
            case EXCEPTION_INVALID_DISPOSITION: return "INVALID_DISPOSITION";
            case EXCEPTION_NONCONTINUABLE_EXCEPTION: return "NONCONTINUABLE_EXCEPTION";
            case EXCEPTION_PRIV_INSTRUCTION: return "PRIV_INSTRUCTION";
            case EXCEPTION_SINGLE_STEP: return "SINGLE_STEP";
            case EXCEPTION_STACK_OVERFLOW: return "STACK_OVERFLOW";
            default: return "UNKNOWN_EXCEPTION";
            }
        }
#endif

    private:
        Logger() = default;
        ~Logger() { Shutdown(); }

        std::string GetTimestamp()
        {
            auto now = std::chrono::system_clock::now();
            auto time = std::chrono::system_clock::to_time_t(now);
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                now.time_since_epoch()) % 1000;

            std::stringstream ss;
            ss << std::put_time(std::localtime(&time), "%Y-%m-%d %H:%M:%S");
            ss << "." << std::setfill('0') << std::setw(3) << ms.count();
            return ss.str();
        }

        std::string LevelToString(Level level)
        {
            switch (level)
            {
            case Level::LOG_DEBUG:   return "DEBUG";
            case Level::LOG_INFO:    return "INFO";
            case Level::LOG_WARNING: return "WARNING";
            case Level::LOG_ERROR:   return "ERROR";
            case Level::LOG_FATAL:   return "FATAL";
            default: return "UNKNOWN";
            }
        }

        std::string ExtractFilename(const std::string& path)
        {
            size_t pos = path.find_last_of("/\\");
            return (pos != std::string::npos) ? path.substr(pos + 1) : path;
        }

        bool m_initialized = false;
        std::string m_logPath;
        std::ofstream m_file;
        std::mutex m_mutex;
        std::vector<LogEntry> m_recentEntries;
        int m_errorCount = 0;
        int m_warningCount = 0;
    };

    // Convenience macros for logging
    #define LOG_DEBUG(category, msg) AppLog::Logger::Instance().Log(AppLog::Level::LOG_DEBUG, category, msg, __FILE__, __LINE__)
    #define LOG_INFO(category, msg) AppLog::Logger::Instance().Log(AppLog::Level::LOG_INFO, category, msg, __FILE__, __LINE__)
    #define LOG_WARNING(category, msg) AppLog::Logger::Instance().Log(AppLog::Level::LOG_WARNING, category, msg, __FILE__, __LINE__)
    #define LOG_ERROR(category, msg) AppLog::Logger::Instance().Log(AppLog::Level::LOG_ERROR, category, msg, __FILE__, __LINE__)
    #define LOG_FATAL(category, msg) AppLog::Logger::Instance().Log(AppLog::Level::LOG_FATAL, category, msg, __FILE__, __LINE__)

    #define LOG_SHADER_ERROR(name, msg) AppLog::Logger::Instance().LogShaderError(name, msg)

#ifdef _WIN32
    #define LOG_D3D12_DEVICE_REMOVED(device) AppLog::Logger::Instance().LogD3D12DeviceRemoved(device)
#endif

} // namespace AppLog

#ifdef _WIN32
// Restore Windows ERROR macro
#pragma pop_macro("ERROR")
#endif
