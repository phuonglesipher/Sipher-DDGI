cmake_minimum_required(VERSION 3.10)
project(ShaderCompiler)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Source files
set(SHADER_COMPILER_SOURCES
    main.cpp
    ShaderManifest.cpp
    Compiler.cpp
    Logger.cpp
    HashCache.cpp
    IncludeParser.cpp
)

set(SHADER_COMPILER_HEADERS
    ShaderManifest.h
    Compiler.h
    Logger.h
    HashCache.h
    IncludeParser.h
    Hash.h
)

# Create executable
add_executable(ShaderCompiler ${SHADER_COMPILER_SOURCES} ${SHADER_COMPILER_HEADERS})

# Include directories
target_include_directories(ShaderCompiler PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/external/dxc/inc
)

# Platform-specific settings
if(WIN32)
    target_compile_definitions(ShaderCompiler PRIVATE _WIN32 NOMINMAX)

    # Link with DXC
    target_link_directories(ShaderCompiler PRIVATE
        ${CMAKE_SOURCE_DIR}/external/dxc/lib/x64
    )
    target_link_libraries(ShaderCompiler PRIVATE dxcompiler)

    # Copy DXC DLLs to output directory
    add_custom_command(TARGET ShaderCompiler POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_SOURCE_DIR}/external/dxc/bin/x64/dxcompiler.dll"
            "$<TARGET_FILE_DIR:ShaderCompiler>"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_SOURCE_DIR}/external/dxc/bin/x64/dxil.dll"
            "$<TARGET_FILE_DIR:ShaderCompiler>"
    )
elseif(UNIX)
    target_compile_definitions(ShaderCompiler PRIVATE __linux__)
    target_link_libraries(ShaderCompiler PRIVATE dl pthread)
endif()

# Set output directory
set_target_properties(ShaderCompiler PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/tools
    RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_BINARY_DIR}/tools
    RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/tools
)
