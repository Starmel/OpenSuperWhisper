# The in-process transform engine: llama.cpp, vendored exactly like whisper.cpp is.
#
# This project owns the ONE ggml in the app image. whisper.cpp is configured with
# WHISPER_USE_SYSTEM_GGML=ON against the ggml package this project installs, so
# the two engines share a single ggml (see libwhisper/CMakeLists.txt and
# Scripts/build-native.sh for the order). Linking whisper's own vendored ggml
# next to this one duplicates ~936 base, ~602 cpu and ~259 metal global symbols
# and fails at link time; never link a second ggml into the app.

# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libllama)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
# Undefine the feature macro to prevent i8mm intrinsics from being used
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

# Only the libraries. No tools, no server, no examples, no tests: the app calls
# the llama C API in-process.
set(LLAMA_BUILD_COMMON   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP      OFF CACHE BOOL "" FORCE)
# mtmd is the multimodal library next to libllama, and it carries the audio
# encoder the Qwen3-ASR engine runs ("qwen3a" projector). It links ggml and
# llama publicly from this same project, so the app still holds exactly one
# ggml. The tools that would use it stay off with LLAMA_BUILD_TOOLS above:
# this option builds the library, not llama-mtmd-cli.
set(LLAMA_BUILD_MTMD     ON  CACHE BOOL "" FORCE)
set(LLAMA_CURL           OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL        OFF CACHE BOOL "" FORCE)

# OpenMP stays off on purpose: it used to be a Homebrew build dependency of this
# repo through `brew install libomp` even though nothing ever called an omp_*
# symbol. The engine is Metal + Accelerate here, and a deterministic OFF keeps a
# stray libomp out of the link line on any machine that happens to have one.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

# Metal with the shaders embedded in the static archive, exactly like the
# whisper build: no .metallib resource, no bundle payload.
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)

add_subdirectory(llama.cpp)

# ---------------------------------------------------------------------------
# Debug builds must not route whisper's Silero VAD through llamafile's sgemm.
#
# whisper_vad_build_lstm_layer() calls
# `ggml_mul_mat(lstm_ih_weight, ggml_transpose(cur))`, and ggml's contiguity test
# exempts dimensions of extent 1, so that transposed operand is classified
# contiguous and ggml-cpu's fast path is entered with `ldb = 1` while `k` is
# lstm_input_size (128). The kernels themselves decline this shape (n == 1 is
# below their minimum), but the eight plain `assert()`s at the top of
# llamafile_sgemm run first, so a Debug build aborts with SIGABRT inside
# whisper_vad_segments_from_samples -- and WhisperEngine runs the VAD on every
# dictation, so every dictation takes the process down.
#
# Release compiles those asserts out (-DNDEBUG), where the same call declines and
# ggml's generic mul_mat computes it correctly. So only the Debug configuration
# drops the fast path: nothing is traded in the build users install, where the
# kernel stays available to whisper's encoder.
#
# This is a per-configuration define rather than a GGML_LLAMAFILE cache variable
# on purpose. The Xcode generator is multi-config: one generated project backs
# both Debug and Release, so a cache variable cannot differ between them -- it
# would flip both, and a Release built after a Debug configure would silently
# lose the kernel. Dropping just this define for Debug is the only way to encode
# "Debug off, Release on" in the project both configurations share.
#
# Do not "tidy" this into a global GGML_LLAMAFILE=OFF.
# Reproduction and analysis: the fm-20260923-11 crew report (vadprobe +
# `Assertion failed: (ldb >= k), function llamafile_sgemm, sgemm.cpp:3813`).
# ---------------------------------------------------------------------------
if(TARGET ggml-cpu)
    get_property(_osw_ggml_cpu_definitions TARGET ggml-cpu PROPERTY COMPILE_DEFINITIONS)
    set(_osw_ggml_cpu_definitions_per_config "")
    foreach(_osw_definition IN LISTS _osw_ggml_cpu_definitions)
        if(_osw_definition STREQUAL "GGML_USE_LLAMAFILE")
            list(APPEND _osw_ggml_cpu_definitions_per_config
                 "$<$<NOT:$<CONFIG:Debug>>:GGML_USE_LLAMAFILE>")
        else()
            list(APPEND _osw_ggml_cpu_definitions_per_config "${_osw_definition}")
        endif()
    endforeach()
    set_property(TARGET ggml-cpu PROPERTY COMPILE_DEFINITIONS
                 "${_osw_ggml_cpu_definitions_per_config}")
endif()
