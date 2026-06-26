#!/bin/bash
set -e

# === Configuration ===
# Usage: ./notarize_app.sh "Developer ID Application: … (TEAMID)" [arm64|x86_64]
#   arm64  (default) — Apple Silicon, all three engines (Whisper, Parakeet, SenseVoice)
#   x86_64           — Intel; SenseVoice is dropped (onnxruntime ships arm64-only), and the
#                      build points Sparkle at its own appcast (appcast-x86_64.xml).
APP_NAME="OpenSuperWhisper"
APP_PATH="./build/Build/Products/Release/OpenSuperWhisper.app"
ZIP_PATH="./build/OpenSuperWhisper.zip"
BUNDLE_ID="fr.my-monkey.opensuperwhisper"
KEYCHAIN_PROFILE="osw-notary"
CODE_SIGN_IDENTITY="${1}"
ARCH="${2:-arm64}"
DEVELOPMENT_TEAM="5C67TFSJ2B"
DMG_NAME="${APP_NAME}-${ARCH}"

if [ "${ARCH}" != "arm64" ] && [ "${ARCH}" != "x86_64" ]; then
  echo "ARCH must be arm64 or x86_64 (got '${ARCH}')"; exit 1
fi
echo "=== Building ${APP_NAME} for ${ARCH} ==="

./Scripts/fetch-sherpa.sh
./Scripts/fetch-libomp-universal.sh

# libwhisper: generic CPU flags (no -mcpu=native) + both arches so either slice can be linked.
rm -rf libwhisper/build
cmake -G Xcode -B libwhisper/build -S libwhisper -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

rm -rf build
mkdir -p build

# autocorrect: universal, pinned to deployment target 14.0 (the SDK default is far higher).
#
# The macOS 26/27 beta toolchain links the Rust dylib with a mis-aligned LINKEDIT string pool
# that ld then rejects for the arm64 slice ("mis-aligned LINKEDIT string pool"), breaking the
# universal build. Until that's fixed upstream, reuse a known-good prebuilt universal dylib when
# one is vendored (the autocorrect source rarely changes); otherwise build from source.
if [ -f vendor/libautocorrect_swift.dylib ]; then
  echo "Using vendored prebuilt autocorrect-swift (beta-toolchain workaround)..."
  cp vendor/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
else
  echo "Building autocorrect-swift (universal)..."
  RUSTC_BIN="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc"
  (
    cd asian-autocorrect
    RUSTFLAGS="-C link-arg=-mmacosx-version-min=14.0" MACOSX_DEPLOYMENT_TARGET=14.0 RUSTC="$RUSTC_BIN" \
      "$HOME/.cargo/bin/cargo" build -p autocorrect-swift --release --target x86_64-apple-darwin
    RUSTFLAGS="-C link-arg=-mmacosx-version-min=14.0" MACOSX_DEPLOYMENT_TARGET=14.0 \
      cargo build -p autocorrect-swift --release --target aarch64-apple-darwin
  )
  lipo -create \
    ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib \
    ./asian-autocorrect/target/x86_64-apple-darwin/release/libautocorrect_swift.dylib \
    -output ./build/libautocorrect_swift.dylib
  install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
fi
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libautocorrect_swift.dylib

echo "Copying libomp.dylib (universal)..."
cp vendor/libomp-universal.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libomp.dylib

# onnxruntime is arm64-only and only the arm64 build links it (OTHER_LDFLAGS[arch=arm64]); the
# x86_64 build still needs the file present for the embed phase, then strips it post-build.
echo "Copying libonnxruntime.dylib..."
cp vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib
ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libonnxruntime.1.24.4.dylib

xcodebuild \
  -scheme "OpenSuperWhisper" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="${ARCH}" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -derivedDataPath build \
  build | xcpretty --simple --color

# Intel build: drop the arm64-only onnxruntime (unused, SenseVoice is compiled out) and point
# Sparkle at the x86_64 feed so the two arch variants never offer each other's downloads.
if [ "${ARCH}" = "x86_64" ]; then
  echo "x86_64: stripping arm64 onnxruntime + setting x86_64 appcast feed..."
  rm -f "${APP_PATH}/Contents/Frameworks/libonnxruntime"*.dylib
  /usr/libexec/PlistBuddy -c \
    "Set :SUFeedURL https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast-x86_64.xml" \
    "${APP_PATH}/Contents/Info.plist"
fi

# Sparkle embeds nested helpers (Updater.app, Autoupdate, XPC services) that each need a
# Developer-ID signature with hardened runtime + secure timestamp; then the outer app must be
# re-signed (re-signing nested code — and our post-build edits — invalidates the bundle seal).
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
  echo "Re-signing Sparkle helpers..."
  SPK="${SPARKLE_FW}/Versions/Current"
  for comp in \
    "${SPK}/XPCServices/Downloader.xpc" \
    "${SPK}/XPCServices/Installer.xpc" \
    "${SPK}/Autoupdate" \
    "${SPK}/Updater.app"; do
    [ -e "${comp}" ] && codesign -f -o runtime --timestamp -s "${CODE_SIGN_IDENTITY}" "${comp}"
  done
  codesign -f -o runtime --timestamp -s "${CODE_SIGN_IDENTITY}" "${SPARKLE_FW}"
fi
# Always re-seal the app (covers the Sparkle re-sign and the x86_64 post-build edits).
codesign -f -o runtime --timestamp \
  --entitlements "OpenSuperWhisper/OpenSuperWhisper.entitlements" \
  -s "${CODE_SIGN_IDENTITY}" "${APP_PATH}"
codesign --verify --strict --verbose=1 "${APP_PATH}"

rm -f "${ZIP_PATH}"
current_dir=$(pwd)
cd $(dirname "${APP_PATH}") && zip -r -y "${current_dir}/${ZIP_PATH}" $(basename "${APP_PATH}")
cd "${current_dir}"

xcrun notarytool submit "${ZIP_PATH}" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
xcrun stapler staple "${APP_PATH}"

# Build the DMG with hdiutil (no extra tooling): the .app + an Applications symlink.
DMG_STAGE="$(mktemp -d)"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
rm -f "${DMG_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG_NAME}.dmg"
rm -rf "${DMG_STAGE}"

codesign --sign "${CODE_SIGN_IDENTITY}" "${DMG_NAME}.dmg"
xcrun notarytool submit "${DMG_NAME}.dmg" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
xcrun stapler staple "${DMG_NAME}.dmg"

echo "Successfully notarized ${APP_NAME} (${ARCH}) → ${DMG_NAME}.dmg"
