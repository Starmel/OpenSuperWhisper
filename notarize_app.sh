#!/bin/bash
set -e

# === Configuration Variables ===
APP_NAME="OpenSuperWhisper"                                   
APP_PATH="./build/Build/Products/Release/OpenSuperWhisper.app"                        
ZIP_PATH="./build/OpenSuperWhisper.zip"                        
BUNDLE_ID="ru.starmel.OpenSuperWhisper"                       
KEYCHAIN_PROFILE="Slava"
CODE_SIGN_IDENTITY="${1}"
DEVELOPMENT_TEAM="8LLDD7HWZK"

# Both engines, one ggml: llama.cpp owns the ggml whisper.cpp builds against.
rm -rf libllama/build libwhisper/build
Scripts/build-native.sh Release

rm -rf build
mkdir -p build

echo "Building autocorrect-swift..."
CARGO_PROFILE_RELEASE_LTO=true \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
CARGO_PROFILE_RELEASE_STRIP=symbols \
CARGO_PROFILE_RELEASE_PANIC=abort \
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=libautocorrect/Cargo.toml
cp ./libautocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libautocorrect_swift.dylib

xcodebuild \
  -scheme "OpenSuperWhisper" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -derivedDataPath build \
  build | xcpretty --simple --color

rm -f "${ZIP_PATH}"

current_dir=$(pwd)
cd $(dirname "${APP_PATH}") && zip -r -y "${current_dir}/${ZIP_PATH}" $(basename "${APP_PATH}")
cd "${current_dir}"

xcrun notarytool submit "${ZIP_PATH}" --wait --keychain-profile "${KEYCHAIN_PROFILE}"

xcrun stapler staple "${APP_PATH}"

# The package is the artifact users install; the DMG only feeds the Homebrew cask.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
packaging/build-pkg.sh \
    --version "${VERSION}" \
    --app "${APP_PATH}" \
    --out "OpenSuperWhisper-${VERSION}.pkg" \
    ${OSW_INSTALLER_IDENTITY:+--sign "${OSW_INSTALLER_IDENTITY}"} \
    ${OSW_NOTARY_PROFILE:+--notarize "${OSW_NOTARY_PROFILE:-$KEYCHAIN_PROFILE}"}

if command -v swifty-dmg >/dev/null 2>&1; then
    swifty-dmg --skipcodesign "${APP_PATH}" --output "${APP_NAME}.dmg" --verbose

    codesign --sign "${CODE_SIGN_IDENTITY}" "${APP_NAME}.dmg"
    xcrun notarytool submit "${APP_NAME}.dmg" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
    xcrun stapler staple "${APP_NAME}.dmg"
else
    echo "swifty-dmg is not installed: skipping the cask DMG (OpenSuperWhisper-${VERSION}.pkg is the artifact)."
    echo "  brew install --cask swifty-dmg, or use the package directly."
fi

echo "Successfully notarized ${APP_NAME}"
