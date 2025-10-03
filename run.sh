#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

# Configure libwhisper
echo "Configuring libwhisper..."
cmake -G Xcode -B libwhisper/build -S libwhisper
if [[ $? -ne 0 ]]; then
    echo "CMake configuration failed!"
    exit 1
fi

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
mv ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

# Build the app
echo "Building OpenSuperWhisper..."
mkdir -p build/ModuleCache build/SwiftPackageCache build/logs
export MODULE_CACHE_DIR="$PWD/build/ModuleCache"
export SWIFTCUSTOMMODULECACHE="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_PACKAGE_CACHE="$PWD/build/SwiftPackageCache"
export SWIFTPM_CUSTOM_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
export SWIFT_PACKAGE_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
mkdir -p "$HOME/.cache/clang/ModuleCache" "$HOME/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading" 2>/dev/null || true

XCODE_LOG="$PWD/build/logs/xcodebuild.log"
CMD=(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build)

"${CMD[@]}" 2>&1 | tee "$XCODE_LOG"
BUILD_STATUS=${PIPESTATUS[0]}

if command -v xcpretty &> /dev/null; then
    xcpretty --simple --color < "$XCODE_LOG"
else
    cat "$XCODE_LOG"
fi

if [[ $BUILD_STATUS -eq 0 ]]; then
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/OpenSuperWhisper.app 2>/dev/null || true
    ./Build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper
else
    echo "Build failed! See $XCODE_LOG for details."
    exit $BUILD_STATUS
fi
