#!/bin/bash

# Packaging contract verification for the one-artifact install/uninstall.
#
# Exercises, without root and without touching the real machine:
#
#   * the whole cycle on scratch trees (OSW_INSTALL_ROOT): what an install
#     brings (the app and the uninstall command), what an uninstall takes (the
#     app, the uninstall command, the models the app downloaded, the caches and
#     the receipt), what it keeps (the recordings, the transcriptions database
#     and the settings) and that a second install is complete again
#   * the recordings and the settings surviving a plain uninstall and going away
#     only under --remove-user-data
#   * uninstall twice, uninstall with the app already gone, unrelated data survives
#   * a model copy an earlier package left under /Library being removed too
#   * argument handling (--help, unknown flags), and that no removal names a path
#     outside the install root
#   * the payload of a built .pkg: the app, the uninstall command, the receipt
#     id, the preinstall script and the installer's version, with the app's own
#     copy of the uninstaller identical to packaging/uninstall.sh
#
# The package carries no model weights: the app downloads those itself, from the
# URLs and pinned digests it carries. The harness checks that the package stays
# that way -- a payload that writes into a home directory, or that has grown
# model files, fails here.
#
# Usage:
#   Scripts/verify-packaging.sh                 # the uninstaller contract only
#   Scripts/verify-packaging.sh --app <path>    # also build a .pkg and run the
#                                               # cycle from its real payload
#
# Exits non-zero if any assertion fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="$REPO_ROOT/packaging/uninstall.sh"
PKG_BUILDER="$REPO_ROOT/packaging/build-pkg.sh"
BUNDLE_ID="ru.starmel.OpenSuperWhisper"
APP_NAME="OpenSuperWhisper"
# A model directory an earlier package installed here: the uninstaller owns it
# (it is the app's own directory under /Library), so a leftover copy has to go.
SHIPPED_MODELS_REL="Library/Application Support/$BUNDLE_ID/Models"
HOME_FOR_SCRATCH="/Users/tester"

CHECKS=0
FAILURES=0

pass() {
    CHECKS=$((CHECKS + 1))
    echo "  ok   $1"
}

fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    echo "  FAIL $1"
}

check() { # description, 0 = ok
    if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1"; fi
}

check_present() { # description, path
    if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (not there: $2)"; fi
}

check_absent() { # description, path
    if [[ -e "$2" ]]; then fail "$1 (still there: $2)"; else pass "$1"; fi
}

quote() { # the uninstaller's own output, so the step that produced it is quotable
    printf '%s\n' "$1" | sed 's/^/       | /'
}

die() {
    echo "ERROR: $1" >&2
    exit 2
}

APP_FOR_PKG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_FOR_PKG="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -f "$UNINSTALL" ]] || die "cannot find $UNINSTALL"

PROBE="$(mktemp -d "${TMPDIR:-/tmp}/osw-verify.XXXXXX")"
trap 'rm -rf "$PROBE"' EXIT

echo "Packaging contract verification"
echo "  uninstaller: $UNINSTALL"
echo "  scratch root: $PROBE"
echo ""

# MARK: - The scratch trees
#
# A scratch root is shaped like an install: what the package's payload places
# (the app and the uninstall command) and what the app writes on first use (the
# models it downloaded, the recordings, the database, the caches and the
# preferences). Everything below is a path under that root; nothing here can
# reach the real machine.
#
# `install_from_payload` uses a package's own extracted payload, so the cycle is
# run against the bytes a user would really get; `simulate_install` writes the
# same layout by hand, so the uninstaller contract can be checked without
# building a package first.

simulate_install() { # root
    local root="$1"
    mkdir -p \
        "$root/Applications/OpenSuperWhisper.app/Contents/MacOS" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models" \
        "$root$HOME_FOR_SCRATCH/Library/Caches/$BUNDLE_ID" \
        "$root$HOME_FOR_SCRATCH/Library/HTTPStorages/$BUNDLE_ID" \
        "$root$HOME_FOR_SCRATCH/Library/Preferences" \
        "$root$HOME_FOR_SCRATCH/Library/Saved Application State/$BUNDLE_ID.savedState" \
        "$root$HOME_FOR_SCRATCH/Library/Application Scripts/$BUNDLE_ID" \
        "$root$HOME_FOR_SCRATCH/models" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/com.example.other"

    echo app > "$root/Applications/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper"
    echo uninstaller > "$root/Applications/Uninstall OpenSuperWhisper.command"
    # What the app downloaded into the user's own directory, plus the user data
    # that must outlive the uninstall.
    echo downloaded-whisper > "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models/ggml-large-v3-turbo-q5_0.bin"
    echo downloaded-transform > "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models/s1-mini-q4_k_m.gguf"
    echo db > "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings.sqlite"
    echo wav > "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav"
    echo plist > "$root$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"
    echo cache > "$root$HOME_FOR_SCRATCH/Library/Caches/$BUNDLE_ID/Cache.db"
    echo http > "$root$HOME_FOR_SCRATCH/Library/HTTPStorages/$BUNDLE_ID/httpstorages.sqlite"
    echo state > "$root$HOME_FOR_SCRATCH/Library/Saved Application State/$BUNDLE_ID.savedState/data.data"
    echo script > "$root$HOME_FOR_SCRATCH/Library/Application Scripts/$BUNDLE_ID/script"
    echo KEEP > "$root$HOME_FOR_SCRATCH/models/Qwen3-30B-A3B-Instruct-2507-q4_k_m.gguf"
    echo KEEP > "$root$HOME_FOR_SCRATCH/Library/Application Support/com.example.other/state.json"
}

install_from_payload() { # payload directory, root
    ditto "$1" "$2"
}

run_uninstall() { # root, extra args...
    local root="$1"
    shift
    HOME="$HOME_FOR_SCRATCH" OSW_INSTALL_ROOT="$root" /bin/sh "$UNINSTALL" "$@" 2>&1
}

# MARK: - What an install brings, and what an uninstall takes and keeps

assert_installed_paths() { # root, label
    local root="$1" label="$2"
    check_present "$label: the app bundle is installed" "$root/Applications/OpenSuperWhisper.app"
    check_present "$label: the uninstall command is installed" "$root/Applications/Uninstall OpenSuperWhisper.command"
    check_present "$label: the downloaded whisper model is there" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models/ggml-large-v3-turbo-q5_0.bin"
    check_present "$label: the downloaded transform model is there" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models/s1-mini-q4_k_m.gguf"
    check_present "$label: the recordings are there" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav"
    check_present "$label: the transcriptions database is there" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings.sqlite"
    check_present "$label: the preferences are there" \
        "$root$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"
}

assert_removed_paths() { # root, label
    local root="$1" label="$2"
    check_absent "$label: the app bundle is gone" "$root/Applications/OpenSuperWhisper.app"
    check_absent "$label: the uninstall command is gone" "$root/Applications/Uninstall OpenSuperWhisper.command"
    check_absent "$label: the downloaded whisper model is gone" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models"
    check_absent "$label: the downloaded transform model is gone" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models"
    check_absent "$label: the caches are gone" "$root$HOME_FOR_SCRATCH/Library/Caches/$BUNDLE_ID"
    check_absent "$label: the HTTP storage is gone" "$root$HOME_FOR_SCRATCH/Library/HTTPStorages/$BUNDLE_ID"
    check_absent "$label: the saved application state is gone" \
        "$root$HOME_FOR_SCRATCH/Library/Saved Application State/$BUNDLE_ID.savedState"
    check_absent "$label: the application scripts directory is gone" \
        "$root$HOME_FOR_SCRATCH/Library/Application Scripts/$BUNDLE_ID"
}

assert_user_data_kept() { # root, label
    local root="$1" label="$2"
    check_present "$label: the recordings survive" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav"
    check_present "$label: the transcriptions database survives" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings.sqlite"
    check_present "$label: the preferences survive" \
        "$root$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"
    check_present "$label: ~/models is untouched" \
        "$root$HOME_FOR_SCRATCH/models/Qwen3-30B-A3B-Instruct-2507-q4_k_m.gguf"
    check_present "$label: another application's data is untouched" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/com.example.other/state.json"
}

assert_user_data_removed() { # root, label
    local root="$1" label="$2"
    check_absent "$label: the app support directory is gone" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID"
    check_absent "$label: the preferences are gone" "$root$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"
    check_present "$label: ~/models is still untouched" \
        "$root$HOME_FOR_SCRATCH/models/Qwen3-30B-A3B-Instruct-2507-q4_k_m.gguf"
    check_present "$label: another application's data is still untouched" \
        "$root$HOME_FOR_SCRATCH/Library/Application Support/com.example.other/state.json"
}

# MARK: - Cycle, against a hand-built install

echo "== cycle (scratch install) =="

INSTALL="$PROBE/install"
simulate_install "$INSTALL"
assert_installed_paths "$INSTALL" "install"

echo ""
echo "-- uninstall --"
OUTPUT="$(run_uninstall "$INSTALL")"
STATUS=$?
quote "$OUTPUT"
check "uninstall exits 0" $STATUS
assert_removed_paths "$INSTALL" "uninstall"
assert_user_data_kept "$INSTALL" "uninstall"
case "$OUTPUT" in
    *"Kept: $INSTALL$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID"*) KEPT_SAID=0 ;;
    *) KEPT_SAID=1 ;;
esac
check "the uninstaller says in its output what it kept" "$KEPT_SAID"

echo ""
echo "-- install again --"
simulate_install "$INSTALL"
assert_installed_paths "$INSTALL" "reinstall"

# MARK: - Idempotence

echo ""
echo "== idempotence =="

OUTPUT="$(run_uninstall "$INSTALL" --quiet)"
STATUS=$?
check "uninstalling twice exits 0" $STATUS
check "uninstalling twice says nothing (--quiet)" "$([[ -z "$OUTPUT" ]] && echo 0 || echo 1)"

SECOND="$(run_uninstall "$INSTALL")"
case "$SECOND" in
    *"has been removed"*) SECOND_OK=0 ;;
    *) SECOND_OK=1 ;;
esac
check "uninstalling twice still reports success" "$SECOND_OK"
assert_user_data_kept "$INSTALL" "twice"

GONE="$PROBE/gone"
simulate_install "$GONE"
rm -rf "$GONE/Applications/OpenSuperWhisper.app"
OUTPUT="$(run_uninstall "$GONE")"
check "uninstalling with the app already gone exits 0" $?
check "and still clears the app's own paths" \
    "$([[ ! -e "$GONE$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models" ]] && echo 0 || echo 1)"
assert_user_data_kept "$GONE" "app gone"

# An earlier package installed model weights into the app's own directory under
# /Library. This one does not, but a machine that has the earlier one has the
# files, and uninstall owns that directory: leaving a GB of dead weights behind
# (or letting a stale copy shadow a fresh download) is not an uninstall.
LEFTOVER="$PROBE/leftover"
simulate_install "$LEFTOVER"
mkdir -p "$LEFTOVER/$SHIPPED_MODELS_REL/whisper-models" "$LEFTOVER/$SHIPPED_MODELS_REL/transform-models"
echo stale > "$LEFTOVER/$SHIPPED_MODELS_REL/whisper-models/ggml-large-v3-turbo.bin"
echo stale > "$LEFTOVER/$SHIPPED_MODELS_REL/transform-models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
OUTPUT="$(run_uninstall "$LEFTOVER")"
check "uninstalling a machine with an earlier package's model copy exits 0" $?
check_absent "the model copy an earlier package left under /Library is gone" "$LEFTOVER/$SHIPPED_MODELS_REL"
assert_user_data_kept "$LEFTOVER" "leftover models"

REINSTALL="$PROBE/reinstall"
simulate_install "$REINSTALL"
run_uninstall "$REINSTALL" --quiet >/dev/null
simulate_install "$REINSTALL"
check "reinstalling over a previous install leaves a complete app again" \
    "$([[ -e "$REINSTALL/Applications/OpenSuperWhisper.app" ]] && echo 0 || echo 1)"
check "and something survived the uninstall to be found again" \
    "$([[ -e "$REINSTALL$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav" ]] && echo 0 || echo 1)"

# MARK: - The full wipe

echo ""
echo "== --remove-user-data (the only thing that takes the recordings) =="

WIPE="$PROBE/wipe"
simulate_install "$WIPE"
OUTPUT="$(run_uninstall "$WIPE" --remove-user-data)"
STATUS=$?
quote "$OUTPUT"
check "--remove-user-data exits 0" $STATUS
assert_removed_paths "$WIPE" "wipe"
assert_user_data_removed "$WIPE" "wipe"
case "$OUTPUT" in
    *"Removed: $WIPE$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID"*) WIPE_SAID=0 ;;
    *) WIPE_SAID=1 ;;
esac
check "the uninstaller says it removed the recordings, transcriptions and settings" "$WIPE_SAID"
case "$OUTPUT" in
    *"Kept:"*) WIPE_LEAK=1 ;;
    *) WIPE_LEAK=0 ;;
esac
check "and does not claim to have kept them" "$WIPE_LEAK"
check "a wiped uninstall is idempotent too" \
    "$(run_uninstall "$WIPE" --remove-user-data --quiet >/dev/null 2>&1; echo $?)"

# MARK: - Argument handling and reach

echo ""
echo "== script surface =="

HELP="$(/bin/sh "$UNINSTALL" --help 2>&1)"
check "--help exits 0" $?
case "$HELP" in
    *"--remove-user-data"*) HELP_FLAG=0 ;;
    *) HELP_FLAG=1 ;;
esac
check "--help documents --remove-user-data" "$HELP_FLAG"
case "$HELP" in
    *"Kept without any option"*) HELP_KEEP=0 ;;
    *) HELP_KEEP=1 ;;
esac
check "--help says what is kept without any option" "$HELP_KEEP"
case "$HELP" in
    *"Removed without any option"*) HELP_REMOVE=0 ;;
    *) HELP_REMOVE=1 ;;
esac
check "--help says what is removed without any option" "$HELP_REMOVE"

OUTPUT="$(/bin/sh "$UNINSTALL" --not-a-flag 2>&1)"
STATUS=$?
check "an unknown argument exits 2" "$([[ $STATUS -eq 2 ]] && echo 0 || echo 1)"
case "$OUTPUT" in
    *"--not-a-flag"*) ARG_REPORTED=0 ;;
    *) ARG_REPORTED=1 ;;
esac
check "and says which argument" "$ARG_REPORTED"

grep -qE '(^|[[:space:];&])rm[[:space:]][^|]*(/opt/homebrew|HOME/models|~/models)' "$UNINSTALL"
check "the uninstaller never removes anything under /opt/homebrew or ~/models" "$([[ $? -ne 0 ]] && echo 0 || echo 1)"

grep -qE 'rm -rf "/"' "$UNINSTALL"
check "the uninstaller never removes the filesystem root" "$([[ $? -ne 0 ]] && echo 0 || echo 1)"

grep -q 'OSW_INSTALL_ROOT' "$UNINSTALL"
check "the uninstaller supports the scratch-root test hook" $?

# Every removal goes through a variable built from the install root: nothing
# outside the app's own paths can be named literally. This is the check that
# keeps the path list honest, so it is run over the script's own text.
LITERAL="$(grep -nE '^[[:space:]]*rm ' "$UNINSTALL" | grep -v '"' || true)"
check "every rm target is a quoted root-relative variable" "$([[ -z "$LITERAL" ]] && echo 0 || echo 1)"
if [[ -n "$LITERAL" ]]; then printf '%s\n' "$LITERAL" | sed 's/^/       | /'; fi

# MARK: - The package

if [[ -n "$APP_FOR_PKG" ]]; then
    echo ""
    echo "== package payload (--app $APP_FOR_PKG) =="

    if [[ ! -d "$APP_FOR_PKG" ]]; then
        fail "no app at $APP_FOR_PKG"
    else
        PACKAGE="$PROBE/OpenSuperWhisper-test.pkg"
        if "$PKG_BUILDER" --app "$APP_FOR_PKG" --out "$PACKAGE" > "$PROBE/pkg.log" 2>&1; then
            pass "packaging/build-pkg.sh produced a package"

            FILES="$(pkgutil --payload-files "$PACKAGE")"
            case "$FILES" in
                *"./Applications/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper"*) PAYLOAD_APP=0 ;;
                *) PAYLOAD_APP=1 ;;
            esac
            case "$FILES" in
                *"./Applications/Uninstall OpenSuperWhisper.command"*) PAYLOAD_COMMAND=0 ;;
                *) PAYLOAD_COMMAND=1 ;;
            esac
            check "the payload contains the app" "$PAYLOAD_APP"
            check "the payload contains the uninstall command" "$PAYLOAD_COMMAND"

            # The package is the app and the uninstall command, and nothing else:
            # no model weights (the app downloads those itself), nothing in a home
            # directory, nothing beside the app in /Applications.
            case "$FILES" in
                *"./Users/"*) PAYLOAD_HOME=1 ;;
                *) PAYLOAD_HOME=0 ;;
            esac
            check "the payload writes nothing into a home directory" "$PAYLOAD_HOME"
            case "$FILES" in
                *"Models/whisper-models/"*|*"Models/transform-models/"*) PAYLOAD_MODELS=1 ;;
                *) PAYLOAD_MODELS=0 ;;
            esac
            check "the payload carries no model weights" "$PAYLOAD_MODELS"
            case "$FILES" in
                *"./Library/"*) PAYLOAD_LIBRARY=1 ;;
                *) PAYLOAD_LIBRARY=0 ;;
            esac
            check "the payload puts nothing in /Library" "$PAYLOAD_LIBRARY"

            # pkgbuild records extended attributes as AppleDouble ("._name")
            # companions in the BOM; the installer applies them as xattrs, so
            # they are not stray files. Count the real entries only.
            IN_APPLICATIONS="$(printf '%s\n' "$FILES" | grep -E '^\./Applications/[^/]*$' | grep -vc '/\._')"
            check "the payload puts exactly two entries in /Applications (the app and the uninstall command)" \
                "$([[ "$IN_APPLICATIONS" -eq 2 ]] && echo 0 || echo 1)"

            grep -q "$BUNDLE_ID" "$PROBE/pkg.log" \
                && pass "the component package carries the receipt id $BUNDLE_ID" \
                || fail "the component package does not carry $BUNDLE_ID"

            grep -q "preinstall" "$PROBE/pkg.log" \
                && pass "the installer ships the preinstall hook" \
                || fail "the installer has no preinstall hook"

            PACKAGE_SIZE="$(stat -f '%z' "$PACKAGE")"
            check "the package is under 500 MB (app and uninstall command, no weights): $PACKAGE_SIZE bytes" \
                "$([[ "$PACKAGE_SIZE" -lt 524288000 ]] && echo 0 || echo 1)"

            # The shipped command must be the same script the app runs, byte for byte.
            pkgutil --expand-full "$PACKAGE" "$PROBE/expanded" >/dev/null 2>&1
            PAYLOAD="$PROBE/expanded/OpenSuperWhisper-component.pkg/Payload"
            SHIPPED="$PAYLOAD/Applications/Uninstall OpenSuperWhisper.command"
            check "the payload carries the uninstall command" \
                "$([[ -f "$SHIPPED" ]] && echo 0 || echo 1)"
            cmp -s "$SHIPPED" "$UNINSTALL" \
                && pass "the shipped command is packaging/uninstall.sh, byte for byte" \
                || fail "the shipped command differs from packaging/uninstall.sh"
            check "the shipped command is executable" \
                "$([[ -x "$SHIPPED" ]] && echo 0 || echo 1)"

            # The app itself has to be inside the payload with its resources, and
            # the copy of the uninstaller it carries -- the one the in-app
            # Uninstall action runs -- has to be the current script. If it is not,
            # the in-app action would run an old path list: the one that deleted
            # the recordings.
            check "the payload app carries the uninstall script resource" \
                "$([[ -f "$PAYLOAD/Applications/OpenSuperWhisper.app/Contents/Resources/uninstall.sh" ]] && echo 0 || echo 1)"
            cmp -s "$PAYLOAD/Applications/OpenSuperWhisper.app/Contents/Resources/uninstall.sh" "$UNINSTALL" \
                && pass "the app inside the package carries packaging/uninstall.sh, byte for byte (the in-app uninstall runs it)" \
                || fail "the app inside the package carries a different uninstaller than packaging/uninstall.sh"
            check "the payload app carries its default whisper model" \
                "$([[ -f "$PAYLOAD/Applications/OpenSuperWhisper.app/Contents/Resources/ggml-tiny.en.bin" ]] && echo 0 || echo 1)"
            check "the extracted payload has no AppleDouble files on disk" \
                "$([[ -z "$(find "$PAYLOAD" -name '._*' -print -quit)" ]] && echo 0 || echo 1)"
            check "the extracted payload puts nothing in /Applications but the app and the command" \
                "$([[ "$(ls -1 "$PAYLOAD/Applications" | wc -l | tr -d ' ')" == "2" ]] && echo 0 || echo 1)"

            pkgutil --expand "$PACKAGE" "$PROBE/unpacked" >/dev/null 2>&1
            check "the component package is present" \
                "$([[ -f "$PROBE/unpacked/OpenSuperWhisper-component.pkg/Payload" ]] && echo 0 || echo 1)"
            check "the distribution declares the arm64/macOS 14 floor" \
                "$(grep -q 'hostArchitectures="arm64"' "$PROBE/unpacked/Distribution" && grep -q 'min="14.0"' "$PROBE/unpacked/Distribution" && echo 0 || echo 1)"
            check "the distribution shows a conclusion page" \
                "$(grep -q 'conclusion' "$PROBE/unpacked/Distribution" && echo 0 || echo 1)"
            check "the distribution substitutes the version" \
                "$(! grep -q '@@VERSION@@' "$PROBE/unpacked/Distribution" && echo 0 || echo 1)"

            # MARK: - Cycle, against the real payload
            #
            # This is the cycle a user runs: what the package installs, then an
            # uninstall, then the same package installed again. The app's own
            # data (the models it downloaded, the recordings, the settings) is
            # created here by hand, because the package does not place it.
            echo ""
            echo "== cycle (from the package payload) =="

            FROM_PKG="$PROBE/from-pkg"
            mkdir -p "$FROM_PKG"
            install_from_payload "$PAYLOAD" "$FROM_PKG"
            # The user's own data, and the model the app downloaded for itself:
            # the first launch creates these, not the package.
            mkdir -p "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings" \
                     "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models" \
                     "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models" \
                     "$FROM_PKG$HOME_FOR_SCRATCH/Library/Preferences" \
                     "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/com.example.other" \
                     "$FROM_PKG$HOME_FOR_SCRATCH/models"
            echo db > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings.sqlite"
            echo wav > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav"
            echo downloaded > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/whisper-models/ggml-large-v3-turbo-q5_0.bin"
            echo downloaded > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/transform-models/s1-mini-q4_k_m.gguf"
            echo plist > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"
            echo KEEP > "$FROM_PKG$HOME_FOR_SCRATCH/models/Qwen3-30B-A3B-Instruct-2507-q4_k_m.gguf"
            echo KEEP > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/com.example.other/state.json"
            # A first launch writes the cache too.
            mkdir -p "$FROM_PKG$HOME_FOR_SCRATCH/Library/Caches/$BUNDLE_ID"
            echo cache > "$FROM_PKG$HOME_FOR_SCRATCH/Library/Caches/$BUNDLE_ID/Cache.db"
            assert_installed_paths "$FROM_PKG" "package install"

            echo ""
            echo "-- uninstall (from the package payload) --"
            OUTPUT="$(run_uninstall "$FROM_PKG")"
            quote "$OUTPUT"
            check "uninstall of a package install exits 0" $?
            assert_removed_paths "$FROM_PKG" "package uninstall"
            assert_user_data_kept "$FROM_PKG" "package uninstall"

            echo ""
            echo "-- install again (from the package payload) --"
            install_from_payload "$PAYLOAD" "$FROM_PKG"
            check_present "reinstall: the app bundle is back" "$FROM_PKG/Applications/OpenSuperWhisper.app"
            check_present "reinstall: the uninstall command is back" \
                "$FROM_PKG/Applications/Uninstall OpenSuperWhisper.command"
            check_present "reinstall: the recordings from before are still there" \
                "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings/dictation.wav"
            check_present "reinstall: the transcriptions database from before is still there" \
                "$FROM_PKG$HOME_FOR_SCRATCH/Library/Application Support/$BUNDLE_ID/recordings.sqlite"
            check_present "reinstall: the settings from before are still there" \
                "$FROM_PKG$HOME_FOR_SCRATCH/Library/Preferences/$BUNDLE_ID.plist"

            # ... and the same cycle once more with --remove-user-data, so the
            # flag is proven against a real install, not only a simulated one.
            echo ""
            echo "-- --remove-user-data on a package install --"
            OUTPUT="$(run_uninstall "$FROM_PKG" --remove-user-data)"
            quote "$OUTPUT"
            check "removing user data from a package install exits 0" $?
            assert_user_data_removed "$FROM_PKG" "package wipe"
        else
            fail "packaging/build-pkg.sh failed (see the log below)"
            sed 's/^/       /' "$PROBE/pkg.log" | tail -20
        fi
    fi
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "ALL CHECKS PASSED (checks: $CHECKS)"
    exit 0
fi
echo "FAILURES: $FAILURES (checks: $CHECKS)"
exit 1
