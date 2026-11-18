# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# ONE ggml in the app image.
#
# The transform engine vendors llama.cpp, which carries a much newer ggml than
# the copy inside whisper.cpp (0.25.0 vs 0.20.2). Linking both archives into one
# binary fails with duplicate symbols (936 shared globals in libggml-base, 602 in
# libggml-cpu, 259 in libggml-metal), so whisper has to build against llama.cpp's
# ggml. That is upstream's supported configuration: WHISPER_USE_SYSTEM_GGML=ON
# makes whisper.cpp `find_package(ggml REQUIRED)` instead of adding its own copy.
#
# The package below is produced by libllama/ (the vendored llama.cpp), which owns
# the single ggml: Scripts/build-native.sh configures and builds libllama, then
# `cmake --install`s its ggml package here before libwhisper is configured. The
# libggml*.a the app links come from libllama's build tree -- the installed
# copies exist only so this configure step can find them.
set(WHISPER_USE_SYSTEM_GGML ON CACHE BOOL "whisper: use system-installed GGML library" FORCE)

if(NOT DEFINED ggml_DIR)
    set(ggml_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../libllama/build/ggml-prefix/lib/cmake/ggml"
        CACHE PATH "directory holding the ggml CMake package installed from libllama")
endif()

if(NOT EXISTS "${ggml_DIR}/ggml-config.cmake")
    message(FATAL_ERROR
        "The vendored ggml package is missing at ${ggml_DIR}.\n"
        "Build it first:  Scripts/build-native.sh\n"
        "(run.sh and notarize_app.sh call that script for you before configuring this project.)")
endif()

add_subdirectory(whisper.cpp)
