# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
# Undefine the feature macro to prevent i8mm intrinsics from being used
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

add_subdirectory(whisper.cpp)
