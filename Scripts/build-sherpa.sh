#!/usr/bin/env bash
#
# Builds sherpa-onnx as a static xcframework for macOS (arm64) and bundles the
# static onnxruntime archive into a single combined library so the app only
# needs to link one product.
#
# Output: libsherpa/sherpa-onnx/build-swift-macos/sherpa-onnx.xcframework
#
# Idempotent: if the xcframework already exists, the build is skipped.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHERPA_DIR="$REPO_ROOT/libsherpa/sherpa-onnx"
BUILD_DIR="$SHERPA_DIR/build-swift-macos"
XCFRAMEWORK="$BUILD_DIR/sherpa-onnx.xcframework"

if [ -d "$XCFRAMEWORK" ]; then
    echo "sherpa-onnx.xcframework already exists, skipping build."
    exit 0
fi

if [ ! -f "$SHERPA_DIR/CMakeLists.txt" ]; then
    echo "sherpa-onnx submodule is missing. Run: git submodule update --init --recursive"
    exit 1
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_INSTALL_PREFIX=./install \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    ../

make -j"$(sysctl -n hw.ncpu)"
make install
rm -fv ./install/include/cargs.h

# Combine the sherpa-onnx static libs into a single library. onnxruntime is
# kept separate and linked alongside, because both sherpa-onnx and onnxruntime
# ship copies of the onnx protobuf objects; merging them into one archive would
# produce duplicate symbols when force-loaded.
libtool -static -o ./install/lib/libsherpa-onnx-combined.a \
    ./install/lib/libsherpa-onnx-c-api.a \
    ./install/lib/libsherpa-onnx-core.a \
    ./install/lib/libkaldi-native-fbank-core.a \
    ./install/lib/libkissfft-float.a \
    ./install/lib/libsherpa-onnx-fstfar.a \
    ./install/lib/libsherpa-onnx-fst.a \
    ./install/lib/libsherpa-onnx-kaldifst-core.a \
    ./install/lib/libkaldi-decoder-core.a \
    ./install/lib/libucd.a \
    ./install/lib/libpiper_phonemize.a \
    ./install/lib/libespeak-ng.a \
    ./install/lib/libssentencepiece_core.a

rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library ./install/lib/libsherpa-onnx-combined.a \
    -headers ./install/include \
    -output "$XCFRAMEWORK"

# Place the static onnxruntime archive next to the xcframework so the app can
# link it via LIBRARY_SEARCH_PATHS + -lonnxruntime.
cp ./install/lib/libonnxruntime.a "$BUILD_DIR/libonnxruntime.a"

echo "Built $XCFRAMEWORK"
echo "Copied $BUILD_DIR/libonnxruntime.a"
