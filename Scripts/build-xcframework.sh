#!/bin/bash
#
# Build whisper.xcframework for macOS + iOS (device + simulator)
#
# Produces a 3-slice dynamic xcframework:
#   1. macOS arm64
#   2. iOS device arm64
#   3. iOS simulator arm64 + x86_64
#
# Output: libwhisper/whisper.cpp/build-apple/whisper.xcframework
#
# Adapted from upstream whisper.cpp/build-xcframework.sh with these changes:
#   - Only 3 slices (no visionOS, tvOS)
#   - CoreML OFF (ADR-002)
#   - OpenMP OFF for all slices (ADR-008)
#   - iOS deployment target 17.0, macOS 14.0
#   - macOS arm64 only (Apple Silicon, matching project convention)
#   - Uses Unix Makefiles generator (Xcode generator broken with CMake 4.x + Xcode 26)
#   - Separate per-arch builds with lipo for simulator fat binary
#

set -eo pipefail

# ----- Configuration -----
IOS_MIN_OS_VERSION=17.0
MACOS_MIN_OS_VERSION=14.0

# Metal GPU acceleration
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_METAL_USE_BF16=ON
GGML_BLAS_DEFAULT=ON

# Disabled features (ADR decisions)
GGML_OPENMP=OFF      # ADR-008: OFF for all slices
WHISPER_COREML=OFF    # ADR-002: CoreML deferred

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

# Parallel jobs for make
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

# ----- Resolve paths -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WHISPER_DIR="${PROJECT_ROOT}/libwhisper/whisper.cpp"

if [ ! -f "${WHISPER_DIR}/CMakeLists.txt" ]; then
    echo "Error: whisper.cpp submodule not found at ${WHISPER_DIR}"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

cd "${WHISPER_DIR}"
echo "Working directory: $(pwd)"

# ----- Tool checks -----
check_required_tool() {
    local tool=$1
    local install_message=$2
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool is required but not found."
        echo "$install_message"
        exit 1
    fi
}

echo "Checking required tools..."
check_required_tool "cmake" "Please install CMake 3.28.0 or later (brew install cmake)"
check_required_tool "xcodebuild" "Please install Xcode and Xcode Command Line Tools (xcode-select --install)"
check_required_tool "libtool" "Should be available with Xcode Command Line Tools (xcode-select --install)"
check_required_tool "dsymutil" "Should be available with Xcode Command Line Tools (xcode-select --install)"
check_required_tool "lipo" "Should be available with Xcode Command Line Tools (xcode-select --install)"

echo "Detected Xcode: $(xcodebuild -version 2>/dev/null | head -n1)"
echo "Detected CMake: $(cmake --version | head -n1)"

# ----- Common CMake args -----
# Note: Uses Unix Makefiles instead of Xcode generator for compatibility
# with CMake 4.x + Xcode 26.x. Per-arch builds with lipo for fat binaries.
COMMON_CMAKE_ARGS=(
    -G "Unix Makefiles"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
    -DWHISPER_COREML=${WHISPER_COREML}
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}"
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}"
)

# ----- Build a single arch -----
# Usage: build_arch <build_dir> <system_name> <sdk_name> <arch> <deployment_target>
build_arch() {
    local build_dir=$1
    local system_name=$2  # "Darwin" for macOS, "iOS" for iOS
    local sdk_name=$3     # "macosx", "iphoneos", "iphonesimulator"
    local arch=$4
    local deployment_target=$5

    echo "  Configuring ${build_dir} (${arch})..."
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk_name}" --show-sdk-path)"

    local extra_args=()
    if [[ "$system_name" == "iOS" ]]; then
        extra_args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="${sdk_path}")
    fi

    cmake -B "${build_dir}" \
        "${COMMON_CMAKE_ARGS[@]}" \
        "${extra_args[@]}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}" \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -S . 2>&1 | grep -E "(error|Error|Including|Configuring done)" || true

    echo "  Building ${build_dir} (${arch})..."
    cmake --build "${build_dir}" -j "${JOBS}" 2>&1 | tail -3
}

# ----- Collect static libs from a build dir -----
collect_static_libs() {
    local build_dir=$1
    local base_dir="$(pwd)"

    local libs=(
        "${base_dir}/${build_dir}/src/libwhisper.a"
        "${base_dir}/${build_dir}/ggml/src/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/libggml-blas.a"
    )

    # Verify all libs exist
    for lib in "${libs[@]}"; do
        if [ ! -f "$lib" ]; then
            echo "Error: Expected static library not found: $lib"
            exit 1
        fi
    done

    echo "${libs[@]}"
}

# ----- Framework structure setup -----
setup_framework_structure() {
    local framework_dir=$1
    local min_os_version=$2
    local platform=$3  # "ios" or "macos"
    local framework_name="whisper"

    echo "  Creating ${platform} framework structure..."

    if [[ "$platform" == "macos" ]]; then
        mkdir -p "${framework_dir}/Versions/A/Headers"
        mkdir -p "${framework_dir}/Versions/A/Modules"
        mkdir -p "${framework_dir}/Versions/A/Resources"

        ln -sf A "${framework_dir}/Versions/Current"
        ln -sf Versions/Current/Headers "${framework_dir}/Headers"
        ln -sf Versions/Current/Modules "${framework_dir}/Modules"
        ln -sf Versions/Current/Resources "${framework_dir}/Resources"
        ln -sf "Versions/Current/${framework_name}" "${framework_dir}/${framework_name}"

        local header_path="${framework_dir}/Versions/A/Headers"
        local module_path="${framework_dir}/Versions/A/Modules"
    else
        mkdir -p "${framework_dir}/Headers"
        mkdir -p "${framework_dir}/Modules"
        rm -rf "${framework_dir}/Versions"

        local header_path="${framework_dir}/Headers"
        local module_path="${framework_dir}/Modules"
    fi

    # Copy headers
    cp include/whisper.h           "${header_path}/"
    cp ggml/include/ggml.h         "${header_path}/"
    cp ggml/include/ggml-alloc.h   "${header_path}/"
    cp ggml/include/ggml-backend.h "${header_path}/"
    cp ggml/include/ggml-metal.h   "${header_path}/"
    cp ggml/include/ggml-cpu.h     "${header_path}/"
    cp ggml/include/ggml-blas.h    "${header_path}/"
    cp ggml/include/gguf.h         "${header_path}/"

    # Module map for Swift import
    cat > "${module_path}/module.modulemap" << 'MODULEMAP'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODULEMAP

    # Info.plist
    local platform_name=""
    local sdk_name=""
    local supported_platform=""
    local plist_path=""
    local device_family=""

    case "$platform" in
        "ios")
            platform_name="iphoneos"
            sdk_name="iphoneos${min_os_version}"
            supported_platform="iPhoneOS"
            plist_path="${framework_dir}/Info.plist"
            device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
        "macos")
            platform_name="macosx"
            sdk_name="macosx${min_os_version}"
            supported_platform="MacOSX"
            plist_path="${framework_dir}/Versions/A/Resources/Info.plist"
            device_family=""
            ;;
    esac

    cat > "${plist_path}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
</dict>
</plist>
EOF
}

# ----- Create dynamic library from static libs -----
# Usage: create_dynamic_lib <combined_a> <output_lib> <dsym_dir> <platform> <is_simulator> <archs...>
create_dynamic_lib() {
    local combined_a=$1
    local output_lib=$2
    local dsym_dir=$3
    local platform=$4
    local is_simulator=$5
    shift 5
    local archs=("$@")

    local sdk=""
    local min_version_flag=""
    local install_name=""
    local frameworks="-framework Foundation -framework Metal -framework Accelerate"

    case "$platform" in
        "ios")
            if [[ "$is_simulator" == "true" ]]; then
                sdk="iphonesimulator"
                min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
            else
                sdk="iphoneos"
                min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
            fi
            install_name="@rpath/whisper.framework/whisper"
            ;;
        "macos")
            sdk="macosx"
            min_version_flag="-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"
            install_name="@rpath/whisper.framework/Versions/Current/whisper"
            ;;
    esac

    local arch_flags=""
    for arch in "${archs[@]}"; do
        arch_flags+=" -arch $arch"
    done

    echo "  Linking dynamic library (${archs[*]})..."
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${combined_a}" \
        $frameworks \
        -install_name "$install_name" \
        -o "${output_lib}"

    # Mark device builds with correct platform version
    if [[ "$is_simulator" == "false" && "$platform" == "ios" ]]; then
        if xcrun -f vtool &>/dev/null 2>&1; then
            echo "  Marking binary for iOS device..."
            xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
                -output "${output_lib}" "${output_lib}"
        else
            echo "  Warning: vtool not found. Binary may not pass App Store validation."
        fi
    fi

    # Generate dSYM
    mkdir -p "${dsym_dir}"
    echo "  Generating dSYM..."
    xcrun dsymutil "${output_lib}" -o "${dsym_dir}/whisper.dSYM"

    # Strip debug symbols from the binary
    local temp_stripped="${output_lib}.stripped"
    xcrun strip -S "${output_lib}" -o "${temp_stripped}"
    mv "${temp_stripped}" "${output_lib}"

    # Remove any auto-generated dSYM in framework structure
    if [ -d "${output_lib}.dSYM" ]; then
        rm -rf "${output_lib}.dSYM"
    fi
}

# ===== BUILD =====

echo ""
echo "=========================================="
echo "Building whisper.xcframework"
echo "  macOS ${MACOS_MIN_OS_VERSION} (arm64)"
echo "  iOS ${IOS_MIN_OS_VERSION} (device arm64)"
echo "  iOS ${IOS_MIN_OS_VERSION} (simulator arm64+x86_64)"
echo "  Metal: ON, CoreML: OFF, OpenMP: OFF"
echo "=========================================="
echo ""

# Clean previous builds (idempotent)
echo "Cleaning previous builds..."
rm -rf build-apple
rm -rf build-ios-sim-arm64
rm -rf build-ios-sim-x86_64
rm -rf build-ios-device
rm -rf build-macos

# ----- 1. iOS Simulator arm64 -----
echo ""
echo "[1/4] iOS Simulator (arm64)..."
build_arch "build-ios-sim-arm64" "iOS" "iphonesimulator" "arm64" "${IOS_MIN_OS_VERSION}"

# ----- 2. iOS Simulator x86_64 -----
echo ""
echo "[2/4] iOS Simulator (x86_64)..."
build_arch "build-ios-sim-x86_64" "iOS" "iphonesimulator" "x86_64" "${IOS_MIN_OS_VERSION}"

# ----- 3. iOS Device arm64 -----
echo ""
echo "[3/4] iOS Device (arm64)..."
build_arch "build-ios-device" "iOS" "iphoneos" "arm64" "${IOS_MIN_OS_VERSION}"

# ----- 4. macOS arm64 -----
echo ""
echo "[4/4] macOS (arm64)..."
build_arch "build-macos" "Darwin" "macosx" "arm64" "${MACOS_MIN_OS_VERSION}"

# ----- Combine simulator architectures with lipo -----
echo ""
echo "Combining simulator architectures..."
BASE_DIR="$(pwd)"

# Collect lib names from one of the sim builds
SIM_ARM64_LIBS=($(collect_static_libs "build-ios-sim-arm64"))
SIM_X86_LIBS=($(collect_static_libs "build-ios-sim-x86_64"))

mkdir -p build-ios-sim-fat/src
mkdir -p build-ios-sim-fat/ggml/src/ggml-metal
mkdir -p build-ios-sim-fat/ggml/src/ggml-blas

# lipo each lib pair into a fat binary
LIB_NAMES=("src/libwhisper.a" "ggml/src/libggml.a" "ggml/src/libggml-base.a" "ggml/src/libggml-cpu.a" "ggml/src/ggml-metal/libggml-metal.a" "ggml/src/ggml-blas/libggml-blas.a")
for lib_rel in "${LIB_NAMES[@]}"; do
    mkdir -p "build-ios-sim-fat/$(dirname "${lib_rel}")"
    lipo -create \
        "build-ios-sim-arm64/${lib_rel}" \
        "build-ios-sim-x86_64/${lib_rel}" \
        -output "build-ios-sim-fat/${lib_rel}"
done
echo "  Fat simulator libraries created."

# ----- Setup framework structures -----
echo ""
echo "Setting up framework structures..."

FRAMEWORK_SIM="build-ios-sim-fat/framework/whisper.framework"
FRAMEWORK_DEVICE="build-ios-device/framework/whisper.framework"
FRAMEWORK_MACOS="build-macos/framework/whisper.framework"

setup_framework_structure "${FRAMEWORK_SIM}" "${IOS_MIN_OS_VERSION}" "ios"
setup_framework_structure "${FRAMEWORK_DEVICE}" "${IOS_MIN_OS_VERSION}" "ios"
setup_framework_structure "${FRAMEWORK_MACOS}" "${MACOS_MIN_OS_VERSION}" "macos"

# ----- Create dynamic libraries -----
echo ""
echo "Creating dynamic libraries..."

# iOS Simulator (fat arm64+x86_64)
echo "  iOS Simulator..."
COMBINED_SIM="${BASE_DIR}/build-ios-sim-fat/temp/combined.a"
mkdir -p "$(dirname "${COMBINED_SIM}")"
libtool -static -o "${COMBINED_SIM}" \
    build-ios-sim-fat/src/libwhisper.a \
    build-ios-sim-fat/ggml/src/libggml.a \
    build-ios-sim-fat/ggml/src/libggml-base.a \
    build-ios-sim-fat/ggml/src/libggml-cpu.a \
    build-ios-sim-fat/ggml/src/ggml-metal/libggml-metal.a \
    build-ios-sim-fat/ggml/src/ggml-blas/libggml-blas.a \
    2> >(grep -v "table of contents" >&2)
create_dynamic_lib "${COMBINED_SIM}" "${FRAMEWORK_SIM}/whisper" "${BASE_DIR}/build-ios-sim-fat/dSYMs" "ios" "true" "arm64" "x86_64"
rm -rf build-ios-sim-fat/temp

# iOS Device (arm64)
echo "  iOS Device..."
COMBINED_DEV="${BASE_DIR}/build-ios-device/temp/combined.a"
mkdir -p "$(dirname "${COMBINED_DEV}")"
libtool -static -o "${COMBINED_DEV}" \
    build-ios-device/src/libwhisper.a \
    build-ios-device/ggml/src/libggml.a \
    build-ios-device/ggml/src/libggml-base.a \
    build-ios-device/ggml/src/libggml-cpu.a \
    build-ios-device/ggml/src/ggml-metal/libggml-metal.a \
    build-ios-device/ggml/src/ggml-blas/libggml-blas.a \
    2> >(grep -v "table of contents" >&2)
create_dynamic_lib "${COMBINED_DEV}" "${FRAMEWORK_DEVICE}/whisper" "${BASE_DIR}/build-ios-device/dSYMs" "ios" "false" "arm64"
rm -rf build-ios-device/temp

# macOS (arm64)
echo "  macOS..."
COMBINED_MAC="${BASE_DIR}/build-macos/temp/combined.a"
mkdir -p "$(dirname "${COMBINED_MAC}")"
libtool -static -o "${COMBINED_MAC}" \
    build-macos/src/libwhisper.a \
    build-macos/ggml/src/libggml.a \
    build-macos/ggml/src/libggml-base.a \
    build-macos/ggml/src/libggml-cpu.a \
    build-macos/ggml/src/ggml-metal/libggml-metal.a \
    build-macos/ggml/src/ggml-blas/libggml-blas.a \
    2> >(grep -v "table of contents" >&2)
create_dynamic_lib "${COMBINED_MAC}" "${FRAMEWORK_MACOS}/Versions/A/whisper" "${BASE_DIR}/build-macos/dSYMs" "macos" "false" "arm64"
rm -rf build-macos/temp

# ----- Create xcframework -----
echo ""
echo "Creating xcframework..."
xcodebuild -create-xcframework \
    -framework "${BASE_DIR}/${FRAMEWORK_SIM}" \
    -debug-symbols "${BASE_DIR}/build-ios-sim-fat/dSYMs/whisper.dSYM" \
    -framework "${BASE_DIR}/${FRAMEWORK_DEVICE}" \
    -debug-symbols "${BASE_DIR}/build-ios-device/dSYMs/whisper.dSYM" \
    -framework "${BASE_DIR}/${FRAMEWORK_MACOS}" \
    -debug-symbols "${BASE_DIR}/build-macos/dSYMs/whisper.dSYM" \
    -output "${BASE_DIR}/build-apple/whisper.xcframework"

# ----- Verify output -----
if [ -d "build-apple/whisper.xcframework" ]; then
    echo ""
    echo "=========================================="
    echo "SUCCESS: whisper.xcframework built"
    echo "Location: ${WHISPER_DIR}/build-apple/whisper.xcframework"
    echo ""
    echo "Slices:"
    ls -d build-apple/whisper.xcframework/*/
    echo "=========================================="
else
    echo ""
    echo "Error: xcframework was not created!"
    exit 1
fi
