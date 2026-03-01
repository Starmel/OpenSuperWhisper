#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

LIBOMP_DYLIB=""

find_libomp_dylib() {
    local candidates=()

    if command -v brew >/dev/null 2>&1; then
        local libomp_prefix
        libomp_prefix=$(brew --prefix libomp 2>/dev/null || true)
        if [[ -n "$libomp_prefix" ]]; then
            candidates+=("$libomp_prefix/lib/libomp.dylib")
        fi

        local brew_prefix
        brew_prefix=$(brew --prefix 2>/dev/null || true)
        if [[ -n "$brew_prefix" ]]; then
            candidates+=("$brew_prefix/opt/libomp/lib/libomp.dylib")
        fi
    fi

    candidates+=(
        "/opt/homebrew/opt/libomp/lib/libomp.dylib"
        "/usr/local/opt/libomp/lib/libomp.dylib"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            LIBOMP_DYLIB="$candidate"
            return 0
        fi
    done

    return 1
}

ensure_libomp() {
    if find_libomp_dylib; then
        return
    fi

    if [[ "${OWS_INSTALL_LIBOMP:-0}" == "1" ]]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo "Homebrew is required to install libomp automatically."
            exit 1
        fi

        echo "libomp not found. Installing via Homebrew..."
        brew install libomp
        if find_libomp_dylib; then
            return
        fi
    fi

    echo "libomp is required but was not found."
    echo "Install with:"
    echo "  brew install libomp"
    echo "Or rerun with:"
    echo "  OWS_INSTALL_LIBOMP=1 ./run.sh build"
    exit 1
}

ensure_metal_toolchain() {
    if xcrun metal -v >/dev/null 2>&1; then
        return
    fi

    if ls /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain/usr/bin/metal >/dev/null 2>&1; then
        return
    fi

    if ls /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*.asset >/dev/null 2>&1; then
        return
    fi

    if [[ "${OWS_INSTALL_METAL_TOOLCHAIN:-0}" == "1" ]]; then
        echo "Metal Toolchain not found. Installing component..."
        xcodebuild -downloadComponent MetalToolchain
        if ! ls /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*.asset >/dev/null 2>&1; then
            echo "Metal Toolchain installation failed."
            exit 1
        fi
        return
    fi

    echo "Metal Toolchain is required for MLX-based LLM post-processing."
    echo "Install once with:"
    echo "  xcodebuild -downloadComponent MetalToolchain"
    echo "Or rerun with:"
    echo "  OWS_INSTALL_METAL_TOOLCHAIN=1 ./run.sh build"
    exit 1
}

echo "Checking Metal Toolchain..."
ensure_metal_toolchain

echo "Checking libomp..."
ensure_libomp

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
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign - ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

echo "Copying libomp.dylib..."
rm -f ./build/libomp.dylib
cp "$LIBOMP_DYLIB" ./build/libomp.dylib
if [[ $? -ne 0 ]]; then
    echo "Failed to copy libomp from $LIBOMP_DYLIB"
    exit 1
fi
chmod u+w ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign - ./build/libomp.dylib

# Build the app
echo "Building OpenSuperWhisper..."
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1)

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $? -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/OpenSuperWhisper.app 2>/dev/null || true
    # Run the app and show logs
    ./Build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper
else
    echo "Build failed!"
    exit 1
fi 
