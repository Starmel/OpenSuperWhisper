#!/bin/bash

# Builds and launches a Debug OpenSuperWhisper that keeps its permission grants
# across rebuilds.
#
# This is run.sh with the three things that broke the permission screen changed:
#
#   1. ENABLE_DEBUG_DYLIB=NO - Xcode's Debug default puts the target's code into
#      OpenSuperWhisper.debug.dylib behind a stub executable. That is not the
#      binary people are testing, and the stub is what makes the bundle look
#      "signed but resource-less" to codesign --verify --deep --strict.
#   2. The bundle is signed with a real (self-signed) identity afterwards, via
#      Scripts/dev-sign.sh, instead of being left unsigned/linker-signed. That
#      gives it the identity-based designated requirement TCC grants survive.
#   3. A build from a linked git worktree gets bundle id
#      ru.starmel.OpenSuperWhisper.dev through OSW_BUNDLE_ID_SUFFIX, so a crew
#      build can never take over the bundle id whose grant is being tested.
#      In the checkout whose app is tested the suffix is empty, as shipped.
#
# Like run.sh, the two vendored engines are built through Scripts/build-native.sh:
# llama.cpp owns the single ggml and whisper.cpp only configures against the
# package that script installs, so that order is not reproduced here.
#
# Usage:
#   Scripts/dev-run.sh              - build, sign, then run the app in the foreground
#   Scripts/dev-run.sh build        - build and sign only
#   Scripts/dev-run.sh test [flags]
#                                   - build, run the unit suite, then re-sign.
#                                     xcodebuild flags are forwarded, so
#                                     `test -only-testing:OpenSuperWhisperTests/Foo`
#                                     runs one class and still ends signed
#   Scripts/dev-run.sh --reset-tcc  - also drop the current Accessibility grant
#                                     before launching (needed once when moving
#                                     off an ad-hoc-signed build; see Readme)
#
# Why `test` is a mode of this script and not a bare xcodebuild: `xcodebuild test`
# rebuilds the app target with CODE_SIGNING_ALLOWED=NO, which leaves the bundle on
# disk linker-signed, i.e. `# designated => cdhash H"..."`. Launching that copy
# reintroduces the exact failure this script exists to prevent - tccd refuses the
# identity requirement the Accessibility grant is stored with (`status: -67050`) -
# so the suite runs here and the bundle is signed and asserted afterwards, whether
# the tests passed or not.
#
# Environment overrides:
#   DEVELOPER_DIR   Xcode to build with (default: /Applications/Xcode.app/Contents/Developer)
#   DEV_SIGN_IDENTITY / DEV_SIGN_KEYCHAIN / DEV_SIGN_ENTITLEMENTS  - see Scripts/dev-sign.sh

set -euo pipefail

# Non-interactive shells (and anything started from a daemon) default to
# /Library/Developer/CommandLineTools, which cannot build an app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# Crew worktrees must not build the shipped bundle id: several bundles sharing
# ru.starmel.OpenSuperWhisper is one of the reasons macOS kept re-prompting for
# Accessibility. A linked git worktree has .git as a file; the checkout whose app
# is being tested has it as a directory. The project turns OSW_BUNDLE_ID_SUFFIX
# into PRODUCT_BUNDLE_IDENTIFIER, so the tested checkout keeps the shipped id.
BUNDLE_ID_SUFFIX=""
if [[ -f .git ]]; then
    BUNDLE_ID_SUFFIX=".dev"
fi
BUNDLE_ID="ru.starmel.OpenSuperWhisper${BUNDLE_ID_SUFFIX}"

APP="$REPO_ROOT/build/Build/Products/Debug/OpenSuperWhisper.app"
APP_BINARY="$APP/Contents/MacOS/OpenSuperWhisper"
DR_RECORD="$REPO_ROOT/build/.dev-sign-dr"

JUST_BUILD=false
RUN_TESTS=false
RESET_TCC=false
TEST_ARGS=()

for arg in "$@"; do
    case "$arg" in
        build) JUST_BUILD=true ;;
        test) RUN_TESTS=true ;;
        --reset-tcc) RESET_TCC=true ;;
        -h|--help)
            awk 'NR > 1 { if ($0 == "set -euo pipefail") exit; sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        # `test` forwards flag-shaped arguments to xcodebuild, so a focused run
        # (`test -only-testing:OpenSuperWhisperTests/SomeTests`) still ends with
        # the signing pass the mode exists for.
        -*) TEST_ARGS+=("$arg") ;;
        *) echo "dev-run.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

for tool in cmake cargo xcodebuild codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "dev-run.sh: missing required tool: $tool" >&2
        exit 1
    fi
done

# Whatever the build or the test run did, the split debug-dylib layout must not
# reach the signing step or a launch: the leftovers are removed, and the script
# fails loudly if they survive the removal, or if the executable is still the
# ~40 KB debug stub (the binary TCC attributes and refuses).
assert_single_binary_layout() {
    local leftover split_left exec_bytes

    for leftover in "$APP/Contents/MacOS"/*.debug.dylib "$APP/Contents/MacOS/__preview.dylib"; do
        [[ -e "$leftover" ]] && rm -f "$leftover"
    done

    split_left="$(find "$APP/Contents/MacOS" -maxdepth 1 \
        \( -name "*.debug.dylib" -o -name "__preview.dylib" \) 2>/dev/null)"
    if [[ -n "$split_left" ]]; then
        echo "dev-run.sh: the bundle still contains Xcode's debug dylib layout:" >&2
        echo "$split_left" >&2
        echo "  a split bundle cannot hold a TCC grant; investigate the build first" >&2
        exit 1
    fi

    exec_bytes="$(stat -f %z "$APP_BINARY" 2>/dev/null || echo 0)"
    if (( exec_bytes < 1000000 )); then
        echo "dev-run.sh: $APP_BINARY is ${exec_bytes} bytes - Xcode's debug stub, not the app." >&2
        echo "  Remove the product and build again:" >&2
        echo "    rm -rf \"$APP\"" >&2
        exit 1
    fi
}

# Reads the designated requirement back off the finished bundle and refuses to
# leave an ad-hoc one behind, because `cdhash H"..."` is invalidated by every
# rebuild and is what makes the Accessibility grant unusable. dev-sign.sh applies
# the same rule at signing time; this asserts the *state of the bundle on disk*,
# so a build, a test run or a bare re-sign all end the same way instead of
# trusting that nothing overwrote the signature afterwards.
assert_identity_requirement() {
    DESIGNATED="$(codesign -d -r- "$APP" 2>&1 \
        | grep -E '^#?[[:space:]]*designated =>' \
        | sed -E 's/^#?[[:space:]]*designated => //')"

    if [[ -z "$DESIGNATED" ]]; then
        echo "dev-run.sh: the bundle has no designated requirement; it is not signed" >&2
        exit 1
    fi
    if [[ "$DESIGNATED" == *"cdhash H"* \
          && "$DESIGNATED" != *"certificate leaf"* \
          && "$DESIGNATED" != *"anchor apple"* ]]; then
        echo "dev-run.sh: the bundle on disk is ad-hoc signed: $DESIGNATED" >&2
        echo "  Launching it would refuse the stored Accessibility grant again." >&2
        echo "  Sign it with the identity: Scripts/dev-sign.sh \"$APP\"" >&2
        exit 1
    fi
}

# A multilingual whisper model this machine happens to have, offered to the
# language-report cases through their documented opt-in. Nothing is exported when
# there is no candidate, which is the state CI runs in: the plain suite must never
# depend on a developer's downloaded files.
multilingual_test_model() {
    local dir file
    for dir in \
        "$REPO_ROOT/.build/test-models" \
        "$HOME/Library/Application Support/ru.starmel.OpenSuperWhisper${BUNDLE_ID_SUFFIX}/whisper-models" \
        "$HOME/Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models"
    do
        [[ -d "$dir" ]] || continue
        for file in "$dir"/*.bin; do
            [[ -e "$file" ]] || continue
            case "$(basename "$file")" in
                # English-only (cannot detect a language), or not a whisper model.
                *.en.bin|*.en-*.bin|ggml-silero*) continue ;;
            esac
            printf '%s\n' "$file"
            return 0
        done
    done
    return 1
}

run_unit_tests() {
    # `xcodebuild test` launches the app-hosted test bundle with a stripped
    # environment: a plain `OSW_TEST_MULTILINGUAL_MODEL=... xcodebuild test` is
    # ignored and the cases skip. XCTest forwards `TEST_RUNNER_<name>` as
    # `<name>`, which is the form that actually arrives, so both are exported.
    local model="${OSW_TEST_MULTILINGUAL_MODEL:-}"

    # A caller-supplied `-only-testing:` narrows the run; without one the whole
    # unit bundle runs.
    local selection=(-only-testing:OpenSuperWhisperTests)
    local arg
    for arg in ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}; do
        if [[ "$arg" == -only-testing:* ]]; then
            selection=()
            break
        fi
    done

    # Each test process gets its own scratch preference suite (AppPreferences),
    # which leaves one small file per process behind in ~/Library/Preferences.
    # Sweep the ones whose process is gone; a suite running in parallel elsewhere
    # is still alive and is therefore left alone.
    local store pid
    for store in "$HOME/Library/Preferences/OpenSuperWhisperTests."*.plist; do
        [[ -e "$store" ]] || continue
        pid="${store##*OpenSuperWhisperTests.}"
        pid="${pid%.plist}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if kill -0 "$pid" 2>/dev/null; then continue; fi
        rm -f "$store"
    done
    if [[ -z "$model" ]]; then
        model="$(multilingual_test_model || true)"
    fi
    if [[ -n "$model" ]]; then
        export OSW_TEST_MULTILINGUAL_MODEL="$model"
        export TEST_RUNNER_OSW_TEST_MULTILINGUAL_MODEL="$model"
        echo "Multilingual cases run against:"
        echo "  $model"
    else
        echo "No multilingual model on this machine; those cases will skip."
    fi

    local status=0
    xcodebuild test -project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisper \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages \
        -skipPackagePluginValidation -skipMacroValidation -skipUnavailableActions \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
        ENABLE_DEBUG_DYLIB=NO \
        OSW_BUNDLE_ID_SUFFIX="$BUNDLE_ID_SUFFIX" \
        ${selection[@]+"${selection[@]}"} \
        ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} || status=$?

    return "$status"
}

# The engines come first, in the one order that works: build-native.sh configures
# and builds libllama (which owns the single ggml), installs that ggml package and
# only then configures libwhisper against it with WHISPER_USE_SYSTEM_GGML=ON.
# Configuring libwhisper directly here fails with "the vendored ggml package is
# missing"; the xcodebuild below builds the two projects this generates.
echo "Building native engines..."
"$SCRIPT_DIR/build-native.sh" Debug

echo "Building autocorrect-swift..."
mkdir -p build
CARGO_PROFILE_RELEASE_LTO=true \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
CARGO_PROFILE_RELEASE_STRIP=symbols \
CARGO_PROFILE_RELEASE_PANIC=abort \
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=libautocorrect/Cargo.toml
cp ./libautocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
# install_name_tool invalidates any existing signature.
codesign --force --sign - ./build/libautocorrect_swift.dylib

# run.sh copies Homebrew's libomp in because the app links -lomp. A branch that
# dropped libomp from the project (and the link flag with it) needs no copy, and
# should not fail when Homebrew's libomp is absent.
if grep -q "libomp" OpenSuperWhisper.xcodeproj/project.pbxproj; then
    if [[ ! -f /opt/homebrew/opt/libomp/lib/libomp.dylib ]]; then
        echo "The project links libomp but /opt/homebrew/opt/libomp/lib/libomp.dylib is missing." >&2
        echo "Install it with: brew install libomp" >&2
        exit 1
    fi
    echo "Copying libomp.dylib..."
    cp -f /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
    install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
    codesign --force --sign - ./build/libomp.dylib
else
    echo "libomp is not part of this project; skipping its dylib."
fi

# A product left in Xcode's split debug-dylib layout cannot be built over. With
# ENABLE_DEBUG_DYLIB=NO the linker writes the real code to
# Contents/MacOS/OpenSuperWhisper, but the previous build's
# OpenSuperWhisper.debug.dylib and __preview.dylib can stay behind, and with
# them the ~40 KB stub executable that loads them - the binary TCC attributes
# and refuses:
#
#   matchesCodeRequirement:]: SecStaticCodeCheckValidity() static code ... from
#   ru.starmel.OpenSuperWhisper : identifier "ru.starmel.OpenSuperWhisper" and
#   certificate leaf = H"32266bcc..."; status: -67050
#
# So the split product is dropped before the build rather than signed as-is.
if [[ -d "$APP" ]]; then
    STALE_SPLIT="$(find "$APP/Contents/MacOS" -maxdepth 1 \
        \( -name "*.debug.dylib" -o -name "__preview.dylib" \) 2>/dev/null)"
    EXEC_BYTES="$(stat -f %z "$APP_BINARY" 2>/dev/null || echo 0)"
    if [[ -n "$STALE_SPLIT" ]] || (( EXEC_BYTES > 0 && EXEC_BYTES < 1000000 )); then
        echo "Removing the split debug-dylib product left by an earlier run.sh build:"
        echo "  $APP"
        rm -rf "$APP"
    fi
fi

# Signing is off during the build: Xcode would try to use the Apple Development
# identity from the project (TEAM 8LLDD7HWZK), which does not exist on this
# machine. Scripts/dev-sign.sh signs the finished bundle instead.
echo "Building OpenSuperWhisper..."
if [[ -n "$BUNDLE_ID_SUFFIX" ]]; then
    echo "  worktree build: bundle id ${BUNDLE_ID}"
fi
# `set -e` would abort at the assignment itself if xcodebuild failed, before the
# captured output below is ever echoed — so a failed build looked like a build
# that simply stopped mid-sentence, with the reason only in
# build/Logs/Build/*.xcactivitylog. Capture the status without errexit, then
# restore it: the failure path below is the one that must be able to speak.
set +e
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 \
    -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES \
    -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    OSW_BUNDLE_ID_SUFFIX="$BUNDLE_ID_SUFFIX" \
    build 2>&1)
BUILD_STATUS=$?
set -e

if command -v xcpretty >/dev/null 2>&1; then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

if [[ $BUILD_STATUS -ne 0 || "$BUILD_OUTPUT" == *"BUILD FAILED"* ]]; then
    echo "Build failed!" >&2
    exit 1
fi

if [[ ! -d "$APP" ]]; then
    echo "Build reported success but there is no bundle at $APP" >&2
    exit 1
fi

# The suite rebuilds the app target ad-hoc, so it runs before the bundle is
# signed and asserted. A failing suite must not skip that: the app on disk has to
# be launchable and grant-bearing whatever the tests said, so the status is kept
# and reported at the end.
TEST_STATUS=0
if $RUN_TESTS; then
    echo "Running the unit suite..."
    run_unit_tests || TEST_STATUS=$?
fi

assert_single_binary_layout

"$SCRIPT_DIR/dev-sign.sh" "$APP"

assert_identity_requirement

# A designated requirement that changes between rebuilds is the exact failure
# this whole path exists to avoid, so remember it and compare. `$DESIGNATED` was
# read back off the bundle by assert_identity_requirement above.
mkdir -p "$(dirname "$DR_RECORD")"
if [[ -f "$DR_RECORD" ]]; then
    PREVIOUS="$(cat "$DR_RECORD")"
    if [[ "$PREVIOUS" == "$DESIGNATED" ]]; then
        echo "Designated requirement unchanged since the previous build:"
        echo "  $DESIGNATED"
    else
        echo "WARNING: the designated requirement changed since the previous build." >&2
        echo "  previous: $PREVIOUS" >&2
        echo "  current:  $DESIGNATED" >&2
        echo "Existing permission grants will no longer match; re-grant once." >&2
    fi
fi
printf '%s' "$DESIGNATED" > "$DR_RECORD"

xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

if $RESET_TCC; then
    # Only when moving from an ad-hoc-signed build: the recorded grant is keyed
    # to the old cdhash requirement and would otherwise be matched to nothing.
    echo "Resetting the Accessibility grant for $BUNDLE_ID..."
    tccutil reset Accessibility "$BUNDLE_ID"
fi

if $JUST_BUILD; then
    echo "Built and signed: $APP"
    exit 0
fi

if $RUN_TESTS; then
    echo "Bundle on disk: $APP"
    echo "  designated requirement: $DESIGNATED"
    if [[ $TEST_STATUS -eq 0 ]]; then
        echo "Unit suite passed and the app is signed for the next launch."
        exit 0
    fi
    echo "Unit suite FAILED; the app was re-signed anyway so the next launch" >&2
    echo "cannot be the ad-hoc copy the test run left behind." >&2
    exit "$TEST_STATUS"
fi

echo "Starting the app..."
exec "$APP_BINARY"
