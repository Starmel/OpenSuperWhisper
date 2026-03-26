#!/bin/zsh

JUST_BUILD=false
BUILD_IOS=false
BUILD_XCFRAMEWORK_ONLY=false

case "$1" in
    build)
        JUST_BUILD=true
        ;;
    build-ios)
        JUST_BUILD=true
        BUILD_IOS=true
        ;;
    build-xcframework)
        BUILD_XCFRAMEWORK_ONLY=true
        ;;
esac

# Phase 1: Build whisper.xcframework (replaces old cmake libwhisper.a path)
echo "Building whisper.xcframework..."
./Scripts/build-xcframework.sh
if [[ $? -ne 0 ]]; then
    echo "xcframework build failed!"
    exit 1
fi
if [[ "$BUILD_XCFRAMEWORK_ONLY" == true ]]; then
    echo "xcframework build complete."
    exit 0
fi

# Phase 2: Build autocorrect-swift (macOS only, not needed for iOS)
if [[ "$BUILD_IOS" != true ]]; then
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
fi

# Phase 3: Build the app
if [[ "$BUILD_IOS" == true ]]; then
    echo "Building OpenSuperWhisper iOS..."
    xcodebuild -scheme OpenSuperWhisper-iOS \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build-ios \
        -skipPackagePluginValidation -skipMacroValidation \
        CODE_SIGNING_ALLOWED=NO build
else
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
fi
