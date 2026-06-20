#!/bin/zsh
#
# dev-codesign.sh — re-sign a freshly built .app with a STABLE code-signing
# identity so macOS TCC permissions (Accessibility, Input Monitoring) survive
# rebuilds. Without this, `run.sh` produces a linker-signed ad-hoc app whose
# identity changes every build, so the system "forgets" granted permissions.
#
# Identity resolution order:
#   1. $2 (explicit argument)
#   2. $OSW_CODESIGN_IDENTITY (environment)
#   3. ./.osw-codesign-identity (gitignored, per-machine file)
#   4. first "Apple Development" identity in the keychain
# If none is found, the ad-hoc signature is left untouched (CI / contributors
# without a developer certificate keep working).
#
# Usage: Scripts/dev-codesign.sh <path-to.app> [identity]

set -e
APP="${1:?usage: dev-codesign.sh <path-to.app> [identity]}"
ENTITLEMENTS="${OSW_ENTITLEMENTS:-OpenSuperWhisper/OpenSuperWhisper.entitlements}"

IDENTITY="${2:-${OSW_CODESIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" && -f ".osw-codesign-identity" ]]; then
    IDENTITY="$(grep -v '^[[:space:]]*#' .osw-codesign-identity | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi

if [[ -z "$IDENTITY" ]]; then
    echo "dev-codesign: no Apple Development identity found — keeping ad-hoc signature."
    exit 0
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "dev-codesign: entitlements not found at $ENTITLEMENTS — keeping ad-hoc signature."
    exit 0
fi

echo "dev-codesign: signing $APP"
echo "             identity: $IDENTITY"

# --deep is fine here: dev convenience re-sign, not distribution. It re-signs
# embedded dylibs/frameworks with the same stable identity in one pass.
codesign --force --deep --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | tail -2
