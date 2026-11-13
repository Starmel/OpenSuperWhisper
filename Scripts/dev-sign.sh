#!/bin/bash

# Signs a locally built OpenSuperWhisper.app so its permissions survive rebuilds.
#
# A Debug build from run.sh is linker-signed at best (run.sh builds with
# CODE_SIGNING_ALLOWED=NO), and an ad-hoc signature yields the designated
# requirement `cdhash H"..."`, which changes on every build. macOS stores
# Accessibility/Microphone/Automation grants in TCC against that requirement, so
# each rebuild invalidates the grant: System Settings keeps showing the switch as
# on while the app is still refused. Signing with a certificate instead makes the
# requirement
#
#   identifier "ru.starmel.OpenSuperWhisper" and certificate leaf = H"..."
#
# which is identical for every rebuild signed with the same identity.
#
# Note that Xcode also emits the target code into OpenSuperWhisper.debug.dylib
# behind a stub executable when ENABLE_DEBUG_DYLIB is YES (the Debug default),
# which is one more reason the bundle does not match what people test. This
# script signs whatever layout it is given; Scripts/dev-run.sh builds with the
# debug dylib disabled.
#
# Usage:
#   Scripts/dev-sign.sh <path-to-app>
#   Scripts/dev-sign.sh --identity "Developer ID Application: X (TEAM)" <path-to-app>
#   Scripts/dev-sign.sh --keychain ~/Library/Keychains/opensuperwhisper-dev.keychain-db <path-to-app>
#
# The identity is picked in this order: --identity/$DEV_SIGN_IDENTITY, an
# existing valid Developer ID Application identity, then the self-signed
# "OpenSuperWhisper Local Dev" identity, which is created on demand by
# Scripts/dev-signing-identity.sh.
#
# Environment overrides:
#   DEV_SIGN_IDENTITY     identity name or SHA-1 to sign with
#   DEV_SIGN_KEYCHAIN     keychain holding that identity
#   DEV_SIGN_ENTITLEMENTS entitlements plist (default: OpenSuperWhisper/OpenSuperWhisper.entitlements)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IDENTITY_SCRIPT="$SCRIPT_DIR/dev-signing-identity.sh"
LOCAL_KEYCHAIN="${DEV_SIGN_KEYCHAIN:-$HOME/Library/Keychains/opensuperwhisper-dev.keychain-db}"
LOCAL_IDENTITY_NAME="${DEV_SIGN_IDENTITY_NAME:-OpenSuperWhisper Local Dev}"
ENTITLEMENTS="${DEV_SIGN_ENTITLEMENTS:-$REPO_ROOT/OpenSuperWhisper/OpenSuperWhisper.entitlements}"
IDENTITY=""

usage() {
    awk 'NR > 1 { if ($0 == "set -euo pipefail") exit; sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:-}"; shift 2 ;;
        --identity=*) IDENTITY="${1#*=}"; shift ;;
        --keychain) DEV_SIGN_KEYCHAIN="${2:-}"; shift 2 ;;
        --keychain=*) DEV_SIGN_KEYCHAIN="${1#*=}"; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "dev-sign.sh: unknown option: $1" >&2; usage 2 ;;
        *) break ;;
    esac
done

if [[ $# -ne 1 ]]; then
    echo "dev-sign.sh: exactly one app bundle path is required" >&2
    usage 2
fi
APP="$1"

if [[ ! -d "$APP" ]]; then
    echo "dev-sign.sh: no app bundle at $APP" >&2
    echo "Build one first with: Scripts/dev-run.sh build" >&2
    exit 1
fi
APP="$(cd "$APP" && pwd)"

if [[ ! -f "$APP/Contents/Info.plist" ]]; then
    echo "dev-sign.sh: $APP is not an app bundle (no Contents/Info.plist)" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "dev-sign.sh: no entitlements at $ENTITLEMENTS" >&2
    echo "Without com.apple.security.accessibility the app cannot ask for Accessibility." >&2
    exit 1
fi

# Signing key material lives in a dedicated keychain, so target it explicitly
# rather than relying on the user's keychain search list.
find_identity() {
    local wanted="$1" keychain="${2:-}"
    if [[ -n "$keychain" && -e "$keychain" ]]; then
        security find-identity -v -p codesigning "$keychain" 2>/dev/null
    else
        security find-identity -v -p codesigning 2>/dev/null
    fi | sed -E 's/^[[:space:]]*[0-9]+\) //' | sed -E 's/^([0-9A-F]+) "(.*)"$/\1\t\2/' |
        grep -F "$wanted" | head -1 || true
}

SIGN_KEYCHAIN=""
if [[ -n "$IDENTITY" ]]; then
    if [[ -n "${DEV_SIGN_KEYCHAIN:-}" ]]; then
        SIGN_KEYCHAIN="$DEV_SIGN_KEYCHAIN"
        MATCH="$(find_identity "$IDENTITY" "$SIGN_KEYCHAIN")"
    else
        MATCH="$(find_identity "$IDENTITY")"
        if [[ -z "$MATCH" && -e "$LOCAL_KEYCHAIN" ]]; then
            MATCH="$(find_identity "$IDENTITY" "$LOCAL_KEYCHAIN")"
            if [[ -n "$MATCH" ]]; then
                SIGN_KEYCHAIN="$LOCAL_KEYCHAIN"
            fi
        fi
    fi
    if [[ -z "$MATCH" ]]; then
        echo "dev-sign.sh: identity not found or not valid: $IDENTITY" >&2
        echo "  list candidates with: security find-identity -v -p codesigning" >&2
        exit 1
    fi
else
    # A real Developer ID is preferred: it comes with a chain of trust and its
    # leaf certificate is just as stable across rebuilds.
    MATCH="$(find_identity 'Developer ID Application:')"
    if [[ -n "$MATCH" ]]; then
        IDENTITY="$(printf '%s' "$MATCH" | cut -f2)"
        echo "Using existing Developer ID identity: $IDENTITY"
    else
        MATCH="$(find_identity "$LOCAL_IDENTITY_NAME" "$LOCAL_KEYCHAIN")"
        if [[ -z "$MATCH" ]]; then
            echo "No code-signing identity found; creating the local one first."
            "$IDENTITY_SCRIPT"
            MATCH="$(find_identity "$LOCAL_IDENTITY_NAME" "$LOCAL_KEYCHAIN")"
        fi
        if [[ -z "$MATCH" ]]; then
            echo "dev-sign.sh: no usable identity even after Scripts/dev-signing-identity.sh" >&2
            exit 1
        fi
        IDENTITY="$(printf '%s' "$MATCH" | cut -f2)"
        SIGN_KEYCHAIN="$LOCAL_KEYCHAIN"
        echo "Using local dev identity: $IDENTITY"
    fi
fi

# The local keychain is created with `set-keychain-settings -lut 43200`, so it
# relocks on sleep. codesign then fails with the opaque `errSecInternalComponent`
# and points at whichever nested bundle it was on, which reads like a broken
# certificate rather than a locked keychain. Scripts/dev-signing-identity.sh
# already stores the password for this; use it instead of failing the build.
#
# The unlock is unconditional, and deliberately not gated on a lock probe:
# `security show-keychain-info` asks for the keychain's password itself when it
# is locked, and a build has nobody to type it - the probe never returns, so
# gating on it hung the whole build (measured: locked keychain, check times out
# at 8 s with stdin redirected and unredirected alike). Unlocking an already
# unlocked keychain is a no-op, so the probe bought nothing and cost a hang.
if [[ -n "$SIGN_KEYCHAIN" && -e "$SIGN_KEYCHAIN" ]]; then
    SIGN_STATE_DIR="${DEV_SIGN_STATE_DIR:-$HOME/.opensuperwhisper-dev}"
    SIGN_PASSWORD_FILE="$SIGN_STATE_DIR/keychain-password"
    if [[ -f "$SIGN_PASSWORD_FILE" ]]; then
        echo "Unlocking $SIGN_KEYCHAIN (it relocks when the machine sleeps)..."
        if ! security unlock-keychain -p "$(cat "$SIGN_PASSWORD_FILE")" "$SIGN_KEYCHAIN" </dev/null; then
            echo "dev-sign.sh: the saved password did not unlock $SIGN_KEYCHAIN." >&2
            echo "  Unlock it by hand, or re-run Scripts/dev-signing-identity.sh to store a new one." >&2
        fi
    else
        echo "dev-sign.sh: no saved keychain password at" >&2
        echo "  $SIGN_PASSWORD_FILE - if $SIGN_KEYCHAIN is locked, codesign fails with" >&2
        echo "  errSecInternalComponent; unlock it by hand, or re-run Scripts/dev-signing-identity.sh" >&2
    fi
fi

CODESIGN_ARGS=(--force --deep --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none)
if [[ -n "$SIGN_KEYCHAIN" ]]; then
    CODESIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi

NESTED=()
while IFS= read -r nested; do
    [[ -n "$nested" ]] && NESTED+=("$nested")
done < <(find "$APP/Contents" -maxdepth 3 \( -name "*.debug.dylib" \) 2>/dev/null)

if (( ${#NESTED[@]} > 0 )); then
    echo "Note: this bundle contains Xcode's debug dylib layout:"
    printf '  %s\n' "${NESTED[@]}"
    echo "  Full entitlements are applied to the nested code so it matches the stub"
    echo "  executable, but Scripts/dev-run.sh builds without the debug dylib."
fi

echo "Signing $APP"
codesign "${CODESIGN_ARGS[@]}" "$APP"

echo "Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP"

# The whole point of this script: fail loudly if the bundle ended up with a
# cdhash-only requirement, because that is what breaks TCC on every rebuild.
# codesign prefixes an ad-hoc requirement with `#`, so it has to be read too -
# otherwise the check below cannot tell ad-hoc from unsigned.
DESIGNATED="$(codesign -d -r- "$APP" 2>&1 \
    | grep -E '^#?[[:space:]]*designated =>' \
    | sed -E 's/^#?[[:space:]]*designated => //' || true)"
if [[ -z "$DESIGNATED" ]]; then
    echo "dev-sign.sh: the bundle has no designated requirement; it is not properly signed" >&2
    codesign -dvvv "$APP" >&2 || true
    exit 1
fi
if [[ "$DESIGNATED" == *"cdhash H"* && "$DESIGNATED" != *"certificate leaf"* && "$DESIGNATED" != *"anchor apple"* ]]; then
    echo "dev-sign.sh: signature is ad-hoc (cdhash-based): $DESIGNATED" >&2
    echo "Such a signature is invalidated by every rebuild, which is exactly the" >&2
    echo "permission problem this script exists to prevent." >&2
    exit 1
fi

if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.accessibility"; then
    echo "dev-sign.sh: signed, but the Accessibility entitlement is not embedded" >&2
    exit 1
fi

echo
echo "Signature OK."
echo "  identity:              $IDENTITY"
echo "  designated requirement: ${DESIGNATED#designated => }"
echo "  entitlements:          $ENTITLEMENTS"
echo
echo "The designated requirement is what macOS matches TCC grants against. It only"
echo "changes if the signing identity changes, not when the app is rebuilt."
