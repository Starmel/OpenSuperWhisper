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

rm -rf libwhisper/build
cmake -G Xcode -B libwhisper/build -S libwhisper

rm -rf build
mkdir -p build

echo "Building autocorrect-swift..."
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
mv ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib

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

swifty-dmg --skipcodesign "${APP_PATH}" --output "${APP_NAME}.dmg" --verbose

codesign --sign "${CODE_SIGN_IDENTITY}" "${APP_NAME}.dmg"
xcrun notarytool submit "${APP_NAME}.dmg" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
xcrun stapler staple "${APP_NAME}.dmg"  

echo "Successfully notarized ${APP_NAME}"
