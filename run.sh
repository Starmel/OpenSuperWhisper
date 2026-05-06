#!/bin/zsh

JUST_BUILD=false
SAVE_BUILD_LOG=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        build)
            JUST_BUILD=true
            ;;
        --save-log=*)
            SAVE_BUILD_LOG="${arg#*=}"
            ;;
        --save-log)
            SAVE_BUILD_LOG="build/xcodebuild_raw_$(date +%Y%m%d_%H%M%S).log"
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [build] [--save-log[=filename]]"
            echo "  build            : Only build, don't run the app"
            echo "  --save-log       : Save raw xcodebuild output to timestamped file"
            echo "  --save-log=FILE  : Save raw xcodebuild output to specific file"
            exit 1
            ;;
    esac
done

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
cp /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign - ./build/libomp.dylib

# Build the app
echo "Building OpenSuperWhisper..."

# Run xcodebuild and capture output while showing it in real-time
if [[ -n "$SAVE_BUILD_LOG" ]]; then
    # Save raw output to file
    echo "Saving raw build output to: $SAVE_BUILD_LOG"
    mkdir -p "$(dirname "$SAVE_BUILD_LOG")"
    
    if command -v xcpretty &> /dev/null; then
        BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1 | tee "$SAVE_BUILD_LOG" | tee >(xcpretty --simple --color >&2))
        BUILD_EXIT_CODE=${PIPESTATUS[0]}
    else
        BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1 | tee "$SAVE_BUILD_LOG" | tee /dev/stderr)
        BUILD_EXIT_CODE=${PIPESTATUS[0]}
    fi
else
    # Don't save to file, just show in console
    if command -v xcpretty &> /dev/null; then
        BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1 | tee >(xcpretty --simple --color >&2))
        BUILD_EXIT_CODE=${PIPESTATUS[0]}
    else
        BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1 | tee /dev/stderr)
        BUILD_EXIT_CODE=${PIPESTATUS[0]}
    fi
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $BUILD_EXIT_CODE -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
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
    if [[ -n "$SAVE_BUILD_LOG" ]]; then
        echo "Raw build output saved to: $SAVE_BUILD_LOG"
        echo "Last 20 lines of build output:"
        tail -20 "$SAVE_BUILD_LOG"
    else
        echo "Last part of build output:"
        echo "$BUILD_OUTPUT" | tail -20
    fi
    exit 1
fi 