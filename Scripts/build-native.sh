#!/bin/zsh

# Builds the two vendored inference engines for OpenSuperWhisper.
#
# Both engines live in the app process behind the shipped Swift wrappers, and
# they share ONE ggml:
#
#   1. libllama  (vendored llama.cpp) is configured and built, and its ggml
#                package is installed into libllama/build/ggml-prefix.
#   2. libwhisper is configured with WHISPER_USE_SYSTEM_GGML=ON against that
#      package, so whisper.cpp does NOT add its own ggml copy.
#
# The app links libllama.a + the ggml set from libllama's build tree and
# libwhisper.a from libwhisper's. Linking whisper.cpp's vendored ggml as well
# fails with duplicate symbols (936 shared globals in libggml-base alone): never
# add a second ggml to the link line.
#
# The Xcode projects the app target references are generated here:
#   libllama/build/libllama.xcodeproj
#   libwhisper/build/libwhisper.xcodeproj
#
# Usage:
#   Scripts/build-native.sh [Debug|Release]      (default: Debug)

set -e

CONFIG="${1:-Debug}"
REPO_ROOT="${0:A:h}/.."
cd "$REPO_ROOT"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# A fresh clone or worktree has empty submodules, and cmake's own complaint about
# a missing llama.cpp/CMakeLists.txt is easy to misread. Say what to run instead.
# (In a linked worktree the submodule URLs are rewritten to local paths, which
# git refuses unless the file transport is allowed: hence the -c below.)
missing=""
for submodule in libllama/llama.cpp libwhisper/whisper.cpp; do
    [ -f "$submodule/CMakeLists.txt" ] || missing="$missing $submodule"
done
if [ -n "$missing" ]; then
    echo "build-native.sh: these submodules are not checked out:$missing" >&2
    echo "  git -c protocol.file.allow=always submodule update --init --recursive" >&2
    exit 1
fi

echo "Configuring libllama (vendored llama.cpp, owns the single ggml)..."
cmake -G Xcode -B libllama/build -S libllama

echo "Building libllama (${CONFIG})..."
cmake --build libllama/build --config "$CONFIG" -j "$JOBS"

echo "Installing the ggml package for whisper.cpp..."
cmake --install libllama/build --config "$CONFIG" --prefix "$PWD/libllama/build/ggml-prefix"

echo "Configuring libwhisper against that ggml (WHISPER_USE_SYSTEM_GGML=ON)..."
cmake -G Xcode -B libwhisper/build -S libwhisper
