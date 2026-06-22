#!/usr/bin/env bash
#
# Fetch the prebuilt sherpa-onnx static xcframework + the onnxruntime dylib into vendor/.
# These power the SenseVoice engine. They are gitignored (76 MB of binaries); this script
# downloads them on demand. Called by run.sh and notarize_app.sh before building.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SHERPA_VER="1.13.3"
ORT_VER="1.24.4"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}"
mkdir -p "$VENDOR"

if [ ! -d "$VENDOR/sherpa-onnx.xcframework" ]; then
  echo "Fetching sherpa-onnx.xcframework v${SHERPA_VER}…"
  curl -fsSL "${BASE}/sherpa-onnx-v${SHERPA_VER}-macos-xcframework-static.tar.bz2" -o /tmp/sherpa-xcf.tar.bz2
  tmp="$(mktemp -d)"; tar xf /tmp/sherpa-xcf.tar.bz2 -C "$tmp"
  mv "$tmp"/*/sherpa-onnx.xcframework "$VENDOR/sherpa-onnx.xcframework"
  rm -rf "$tmp" /tmp/sherpa-xcf.tar.bz2
fi

if [ ! -f "$VENDOR/onnxruntime/libonnxruntime.${ORT_VER}.dylib" ]; then
  echo "Fetching onnxruntime ${ORT_VER} dylib…"
  curl -fsSL "${BASE}/sherpa-onnx-v${SHERPA_VER}-onnxruntime-${ORT_VER}-osx-arm64-shared.tar.bz2" -o /tmp/ort.tar.bz2
  tmp="$(mktemp -d)"; tar xf /tmp/ort.tar.bz2 -C "$tmp"
  mkdir -p "$VENDOR/onnxruntime"
  cp "$tmp"/*/lib/libonnxruntime.${ORT_VER}.dylib "$VENDOR/onnxruntime/"
  ln -sf "libonnxruntime.${ORT_VER}.dylib" "$VENDOR/onnxruntime/libonnxruntime.dylib"
  rm -rf "$tmp" /tmp/ort.tar.bz2
fi

echo "sherpa-onnx vendored in vendor/."
