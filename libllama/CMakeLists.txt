cmake_minimum_required(VERSION 3.20)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_C_FLAGS_INIT   "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
set(CMAKE_CXX_STANDARD 17)

project(libllama_grammar)

# Build llama.cpp as a shared library so its ggml lives separately
# from whisper.cpp's ggml — this prevents duplicate symbol conflicts.
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER  OFF CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)

add_subdirectory(llama.cpp)

# Thin C++ grammar-correction wrapper.
# Built as a separate shared library that links against llama.
add_library(llama_grammar SHARED
    llama_grammar_helper.cpp
)

target_include_directories(llama_grammar PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/include
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/include
)

target_link_libraries(llama_grammar PRIVATE llama)

set_target_properties(llama_grammar PROPERTIES
    INSTALL_RPATH "@loader_path"
    BUILD_RPATH   "@loader_path"
)
