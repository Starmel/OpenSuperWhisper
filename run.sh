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

# Build libllama_grammar.dylib (llama.cpp + grammar helper, built as dylib
# to avoid ggml symbol conflicts with whisper.cpp's statically-linked ggml)
if [[ -d "libllama/llama.cpp" ]]; then
    echo "Building libllama_grammar..."
    cmake -B libllama/build -S libllama \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DGGML_METAL=ON \
        -DCMAKE_CXX_FLAGS="-fvisibility=hidden" \
        -DCMAKE_C_FLAGS="-fvisibility=hidden"
    if [[ $? -ne 0 ]]; then
        echo "libllama CMake configuration failed!"
        exit 1
    fi
    cmake --build libllama/build --config Release -j8
    if [[ $? -ne 0 ]]; then
        echo "libllama build failed!"
        exit 1
    fi

    # Copy dylibs to build/ where the app can find them
    mkdir -p build
    LLAMA_DYLIB=$(find libllama/build -name "libllama_grammar*.dylib" | head -1)
    LLAMA_CORE=$(find libllama/build -name "libllama*.dylib" | grep -v grammar | head -1)
    LLAMA_GGML=$(find libllama/build -name "libggml*.dylib" | head -1)

    for dylib in "$LLAMA_DYLIB" "$LLAMA_CORE" "$LLAMA_GGML"; do
        [[ -z "$dylib" ]] && continue
        name=$(basename "$dylib")
        cp "$dylib" "build/$name"
        install_name_tool -id "@rpath/$name" "build/$name"
        codesign --force --sign - "build/$name"
    done
    echo "libllama_grammar built and copied to build/"
else
    echo "Skipping libllama build (libllama/llama.cpp not found)."
    echo "Run: git submodule add https://github.com/ggerganov/llama.cpp.git libllama/llama.cpp"
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