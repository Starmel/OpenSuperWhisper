#!/bin/bash

# Creates a self-signed code-signing identity for local development builds, so
# that locally built copies of the app carry an *identity-based* designated
# requirement instead of a cdhash-only one.
#
# Why it matters: an ad-hoc signature (`codesign --sign -`) produces a
# designated requirement of the form `cdhash H"..."`, which changes on every
# rebuild. macOS keys Accessibility/Microphone/Automation grants in the TCC
# database on that requirement, so every rebuild silently invalidates the grant
# and System Settings shows the toggle as on while the app is still refused.
# Signing with a certificate makes the requirement
# `identifier "ru.starmel.OpenSuperWhisper" and certificate leaf = H"..."`,
# which survives rebuilds, so the grant is granted once per identity.
#
# The identity lives in its own keychain and needs no sudo and no Apple account.
# Nothing global is modified: the keychain is not added to the keychain search
# list, the login keychain is untouched, and the certificate is trusted for the
# code-signing policy in the *user* trust domain only.
#
# Usage:
#   Scripts/dev-signing-identity.sh           - create the identity if missing (idempotent)
#   Scripts/dev-signing-identity.sh --check   - report the identity, create nothing
#   Scripts/dev-signing-identity.sh --remove  - delete the keychain and local state
#
# Environment overrides:
#   DEV_SIGN_IDENTITY_NAME   identity (certificate CN)   (default: OpenSuperWhisper Local Dev)
#   DEV_SIGN_KEYCHAIN_NAME   keychain file name          (default: opensuperwhisper-dev.keychain-db)
#   DEV_SIGN_STATE_DIR       keychain password lives here (default: $HOME/.opensuperwhisper-dev)
#
# Removal (also done by --remove, no sudo):
#   security delete-keychain "$HOME/Library/Keychains/opensuperwhisper-dev.keychain-db" && rm -rf "$HOME/.opensuperwhisper-dev"
# Deleting the keychain also removes its trust settings; the login keychain and
# any grant already recorded in the TCC database are left alone.

set -euo pipefail

IDENTITY_NAME="${DEV_SIGN_IDENTITY_NAME:-OpenSuperWhisper Local Dev}"
KEYCHAIN_NAME="${DEV_SIGN_KEYCHAIN_NAME:-opensuperwhisper-dev.keychain-db}"
STATE_DIR="${DEV_SIGN_STATE_DIR:-$HOME/.opensuperwhisper-dev}"
KEYCHAIN_DIR="$HOME/Library/Keychains"
KEYCHAIN_PATH="$KEYCHAIN_DIR/$KEYCHAIN_NAME"
PASSWORD_FILE="$STATE_DIR/keychain-password"
CERT_VALIDITY_DAYS="${DEV_SIGN_CERT_DAYS:-3650}"

usage() {
    awk 'NR > 1 { if ($0 == "set -euo pipefail") exit; sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

MODE="ensure"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    --remove) MODE="remove" ;;
    -h|--help) usage 0 ;;
    *) echo "dev-signing-identity.sh: unknown argument: $1" >&2; usage 2 ;;
esac

# Any valid Developer ID in the user's keychains beats a self-signed one: it is
# backed by a real chain of trust and its leaf certificate is just as stable.
preferred_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null |
        grep -E '"Developer ID Application: ' |
        head -1 |
        sed -E 's/^[[:space:]]*[0-9]+\) ([0-9A-F]+) "(.*)"/\1 \2/' || true
}

# The leaf certificate hash is the part of the designated requirement that must
# stay constant across rebuilds; print it because it is the thing to compare.
local_identity() {
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null |
        grep -F "\"$IDENTITY_NAME\"" |
        head -1 |
        sed -E 's/^[[:space:]]*[0-9]+\) ([0-9A-F]+) "(.*)"/\1 \2/' || true
}

if [[ "$MODE" == "remove" ]]; then
    if [[ -e "$KEYCHAIN_PATH" ]]; then
        security delete-keychain "$KEYCHAIN_PATH"
        echo "Deleted keychain: $KEYCHAIN_PATH"
    else
        echo "No keychain at $KEYCHAIN_PATH"
    fi
    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        echo "Deleted local state: $STATE_DIR"
    fi
    echo "Trust settings disappear with the keychain; no sudo was needed and nothing else was changed."
    exit 0
fi

DEVELOPER_ID="$(preferred_developer_id)"
EXISTING="$(local_identity)"

if [[ -n "$EXISTING" ]]; then
    echo "Identity is ready: $EXISTING"
    echo "  keychain: $KEYCHAIN_PATH"
elif [[ -n "$DEVELOPER_ID" ]]; then
    echo "A valid Developer ID identity already exists; prefer it over a self-signed one:"
    echo "  $DEVELOPER_ID"
    echo "Scripts/dev-sign.sh picks it up automatically; no self-signed identity was created."
else
    if [[ "$MODE" == "check" ]]; then
        echo "No usable code-signing identity found." >&2
        echo "  Developer ID identity: none valid" >&2
        echo "  Self-signed identity:  none at $KEYCHAIN_PATH" >&2
        echo "Run 'Scripts/dev-signing-identity.sh' to create the self-signed one." >&2
        exit 1
    fi

    echo "Creating self-signed code-signing identity \"$IDENTITY_NAME\" (no sudo, no Apple account)..."

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [[ ! -f "$PASSWORD_FILE" ]]; then
        umask 077
        # Only protects the local signing key; it is not a secret worth deriving.
        openssl rand -base64 24 | tr -d '\n' > "$PASSWORD_FILE"
        echo "  generated keychain password: $PASSWORD_FILE"
    fi
    KEYCHAIN_PASSWORD="$(cat "$PASSWORD_FILE")"

    # `security` resolves a bare keychain name inside $HOME/Library/Keychains,
    # which keeps this script independent of the caller's working directory.
    if [[ -e "$KEYCHAIN_PATH" ]]; then
        echo "  reusing keychain: $KEYCHAIN_PATH"
    else
        security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
        echo "  created keychain: $KEYCHAIN_PATH"
    fi
    # Long lock timeout: a locked keychain would make codesign prompt for a
    # password in the middle of a build. The script unlocks it either way.
    security set-keychain-settings -lut 43200 "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

    STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opensuperwhisper-dev-sign.XXXXXX")"
    trap 'rm -rf "$STAGING_DIR"' EXIT

    # A code-signing certificate: self-signed leaf, codeSigning EKU, no CA.
    cat > "$STAGING_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = codesign_ext

[ dn ]
CN = $IDENTITY_NAME

[ codesign_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$STAGING_DIR/key.pem" \
        -out "$STAGING_DIR/cert.pem" \
        -days "$CERT_VALIDITY_DAYS" \
        -config "$STAGING_DIR/openssl.cnf" 2>/dev/null

    # Import the key and the certificate separately: a PKCS#12 round trip needs
    # `-legacy` on OpenSSL 3 and is rejected by `security import` without it.
    security import "$STAGING_DIR/key.pem" -k "$KEYCHAIN_PATH" \
        -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
    security import "$STAGING_DIR/cert.pem" -k "$KEYCHAIN_PATH" \
        -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
    echo "  imported key and certificate"

    # Without a partition list entry, every codesign run asks the user to allow
    # key access through a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    echo "  allowed codesign to use the key without prompting"

    # codesign refuses an untrusted identity ("no identity found"), so trust the
    # certificate for the code-signing policy in the user trust domain. This is
    # the only step that touches trust settings and it needs no sudo.
    if ! security add-trusted-cert -r trustRoot -p codeSign \
        -k "$KEYCHAIN_NAME" "$STAGING_DIR/cert.pem" 2>"$STAGING_DIR/trust.err"; then
        if ! security add-trusted-cert -r trustRoot -p codeSign \
            -k "$KEYCHAIN_PATH" "$STAGING_DIR/cert.pem" 2>>"$STAGING_DIR/trust.err"; then
            echo "Failed to trust the certificate for code signing:" >&2
            sed 's/^/  /' "$STAGING_DIR/trust.err" >&2
            echo "Manual equivalent:" >&2
            echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$KEYCHAIN_NAME\" \"$STAGING_DIR/cert.pem\"" >&2
            exit 1
        fi
    fi
    echo "  trusted the certificate for code signing (user domain)"

    EXISTING="$(local_identity)"
    if [[ -z "$EXISTING" ]]; then
        echo "Identity was not usable after creation. Diagnose with:" >&2
        echo "  security find-identity -v -p codesigning \"$KEYCHAIN_PATH\"" >&2
        exit 1
    fi
    echo "Identity created: $EXISTING"
    echo "  keychain: $KEYCHAIN_PATH"
fi

echo "The hash above is the leaf certificate hash: it is what the designated"
echo "requirement pins, so it stays the same across rebuilds."
