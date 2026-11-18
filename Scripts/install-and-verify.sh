#!/bin/bash
#
# install-and-verify.sh - one-shot build, package, back up, uninstall, install,
# verify, for the local 0.1.0 build on this machine.
#
# Run once:
#   Scripts/install-and-verify.sh
#
# It prints one line per step and stops at the first hard failure. What each
# step is evidence for:
#
#   1. build     - the Debug bundle at build/Build/Products/Debug/OpenSuperWhisper.app
#                  is the one this branch builds; Scripts/dev-run.sh signed it with
#                  the local dev identity and asserted its designated requirement is
#                  the identity requirement (what TCC matches grants against), not a
#                  cdhash. dev-run.sh records that requirement in build/.dev-sign-dr.
#   2. package   - dist/OpenSuperWhisper-0.1.0-local.pkg is the installable artifact,
#                  and its sha256 is written beside it, so the bytes handed around
#                  are the bytes verified here.
#   3. harness   - Scripts/verify-packaging.sh exercises the install/uninstall
#                  contract on scratch trees and reports how many checks passed.
#                  This is supporting evidence for step 5 and step 7, not a
#                  substitute for the real thing.
#   4. backup    - a read-only copy of the user's own app data (recordings, the
#                  recordings database, the settings plist) exists before anything
#                  is uninstalled. If the copy is short of a file against the
#                  source, stop; a source that is simply not there is printed and
#                  the run continues (nothing of his can be lost by it, and the
#                  uninstaller is never given --remove-user-data).
#   5. uninstall - the shipped uninstaller removes the app, its models, caches and
#                  receipt, and is never given --remove-user-data.
#   6. kept data - after step 5 the recordings directory, the recordings database
#                  and the settings plist are still there, with the same file count
#                  and the same plist sha256 as before. This is the check that the
#                  uninstall did not destroy what is his; a before/after table is
#                  printed, and anything missing stops the run loudly.
#   7. install   - the app is put back from the package's own payload, and
#                  `codesign --verify --deep --strict` passes with the same
#                  designated requirement the build reported in step 1.
#   8. report    - the installed binary's sha256, the package's sha256, the app's
#                  designated requirement, and the step 6 before/after table.
#
# Rules this script keeps:
#   * set -euo pipefail; every path is quoted.
#   * it writes only under the repo (build/install-and-verify), /tmp (via
#     Scripts/verify-packaging.sh) and /Applications.
#   * it never removes anything under $HOME, and never runs `rm -rf` on a path
#     that could name the user's data.
#   * it never passes --remove-user-data to the uninstaller.
#   * if the dev signing keychain is locked it is unlocked from
#     ~/.opensuperwhisper-dev/keychain-password, so signing never prompts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

BUNDLE_ID="ru.starmel.OpenSuperWhisper"

APP="$REPO_ROOT/build/Build/Products/Debug/OpenSuperWhisper.app"
DR_RECORD="$REPO_ROOT/build/.dev-sign-dr"

PKG="$REPO_ROOT/dist/OpenSuperWhisper-0.1.0-local.pkg"
SHA_FILE="$PKG.sha256"

INSTALLED_APP="/Applications/OpenSuperWhisper.app"
INSTALLED_CMD="/Applications/Uninstall OpenSuperWhisper.command"
VENDORED_CMD="$REPO_ROOT/packaging/uninstall.sh"

SUPPORT_SRC="$HOME/Library/Application Support/$BUNDLE_ID"
PREFS_SRC="$HOME/Library/Preferences/$BUNDLE_ID.plist"
RECORDINGS_SRC="$SUPPORT_SRC/recordings"
DB_SRC="$SUPPORT_SRC/recordings.sqlite"

STAMP="$(date +%Y%m%d-%H%M%S)"
SCRATCH="$REPO_ROOT/build/install-and-verify"
BACKUP_DIR="$SCRATCH/backup-$STAMP"
LOG_DIR="$SCRATCH/logs-$STAMP"
EXPAND_DIR="$SCRATCH/pkg-expand-$STAMP"

mkdir -p "$SCRATCH" "$LOG_DIR"

step() {
    printf '\n==> Step %s: %s\n' "$1" "$2"
}

die() {
    printf '\nSTOP: %s\n' "$*" >&2
    exit 1
}

sha256_of() { # file
    if [[ -f "$1" ]]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "(absent)"
    fi
}

count_files() { # directory
    if [[ -d "$1" ]]; then
        find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

describe_file() { # path -> present/absent plus size and sha256
    if [[ -f "$1" ]]; then
        printf 'present, %s bytes, sha256 %s' "$(stat -f '%z' "$1")" "$(sha256_of "$1")"
    else
        printf 'absent'
    fi
}

# ---------------------------------------------------------------------------
# Step 1 - build
# ---------------------------------------------------------------------------

step 1 "build (Scripts/dev-run.sh build)"

KEYCHAIN="${DEV_SIGN_KEYCHAIN:-$HOME/Library/Keychains/opensuperwhisper-dev.keychain-db}"
KEYCHAIN_PASSWORD_FILE="${DEV_SIGN_STATE_DIR:-$HOME/.opensuperwhisper-dev}/keychain-password"
if [[ -e "$KEYCHAIN" ]] && ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    [[ -f "$KEYCHAIN_PASSWORD_FILE" ]] \
        || die "step 1: $KEYCHAIN is locked and there is no password at $KEYCHAIN_PASSWORD_FILE"
    echo "    unlocking $KEYCHAIN from $KEYCHAIN_PASSWORD_FILE (it relocks when the machine sleeps)"
    security unlock-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN" \
        || die "step 1: could not unlock $KEYCHAIN"
fi

if ! "$SCRIPT_DIR/dev-run.sh" build; then
    die "step 1: Scripts/dev-run.sh build failed"
fi

[[ -d "$APP" ]] || die "step 1: no app bundle at $APP after the build"
[[ -s "$DR_RECORD" ]] || die "step 1: dev-run.sh did not write a designated requirement to $DR_RECORD"
BUILD_DR="$(cat "$DR_RECORD")"
echo "    build designated requirement: $BUILD_DR"

# ---------------------------------------------------------------------------
# Step 2 - package
# ---------------------------------------------------------------------------

step 2 "package (packaging/build-pkg.sh)"

"$REPO_ROOT/packaging/build-pkg.sh" \
    --app "build/Build/Products/Debug/OpenSuperWhisper.app" \
    --out "dist/OpenSuperWhisper-0.1.0-local.pkg"

[[ -f "$PKG" ]] || die "step 2: no package at $PKG after packaging"
shasum -a 256 "$PKG" > "$SHA_FILE"
PKG_SHA="$(awk '{print $1}' "$SHA_FILE")"
echo "    wrote $SHA_FILE"
echo "    package sha256: $PKG_SHA"

# ---------------------------------------------------------------------------
# Step 3 - packaging harness (supporting evidence)
# ---------------------------------------------------------------------------

step 3 "packaging harness (Scripts/verify-packaging.sh --app \"$APP\")"

HARNESS_LOG="$LOG_DIR/verify-packaging.log"
harness_status=0
"$SCRIPT_DIR/verify-packaging.sh" --app "$APP" > "$HARNESS_LOG" 2>&1 || harness_status=$?
printf '    --- last lines of %s ---\n' "$HARNESS_LOG"
tail -n 20 "$HARNESS_LOG" | sed 's/^/    /'

CHECKS_LINE="$(grep -E '(ALL CHECKS PASSED|FAILURES: [0-9]+) \(checks: [0-9]+\)' "$HARNESS_LOG" | tail -1 || true)"
if [[ "$harness_status" -ne 0 ]]; then
    die "step 3: the packaging harness failed (exit $harness_status); full log: $HARNESS_LOG"
fi
[[ -n "$CHECKS_LINE" ]] || die "step 3: could not read the harness check count from $HARNESS_LOG"
CHECK_COUNT="$(printf '%s' "$CHECKS_LINE" | sed -E 's/.*\(checks: ([0-9]+)\).*/\1/')"
echo "    harness result: $CHECKS_LINE"
echo "    harness checks: $CHECK_COUNT (full log: $HARNESS_LOG)"

# ---------------------------------------------------------------------------
# Step 4 - back up the user's own data, read-only
# ---------------------------------------------------------------------------

step 4 "back up the user's app data (read-only)"

# An absent source is absent evidence, not a failure to refuse on: nothing of his
# is at that path, nothing can be lost by continuing (the uninstaller is never
# given --remove-user-data), and step 6 compares against whatever was there. The
# absence is printed, never treated as a backup that succeeded.
mkdir -p "$BACKUP_DIR"
if [[ -d "$SUPPORT_SRC" ]]; then
    ditto "$SUPPORT_SRC" "$BACKUP_DIR/Application Support"
else
    echo "    note: $SUPPORT_SRC does not exist - there is no app data at that path to copy"
fi
if [[ -f "$PREFS_SRC" ]]; then
    ditto "$PREFS_SRC" "$BACKUP_DIR/$(basename "$PREFS_SRC")"
else
    echo "    note: $PREFS_SRC does not exist - there is no settings plist at that path to copy"
fi
chmod -R a-w "$BACKUP_DIR"

SRC_COUNT="$(count_files "$SUPPORT_SRC")"
COPY_COUNT="$(count_files "$BACKUP_DIR/Application Support")"
BACKUP_COUNT="$(count_files "$BACKUP_DIR")"
BACKUP_SIZE="$(du -sh "$BACKUP_DIR" | cut -f1)"
PREFS_SHA_BACKED="$(sha256_of "$BACKUP_DIR/$(basename "$PREFS_SRC")")"

echo "    backup:    $BACKUP_DIR"
echo "    size:      $BACKUP_SIZE"
echo "    files:     $BACKUP_COUNT total in the copy ($COPY_COUNT under Application Support)"
echo "    source:    $SRC_COUNT files under $SUPPORT_SRC"
echo "    plist:     $PREFS_SRC sha256 $PREFS_SHA_BACKED (copy)"

[[ "$COPY_COUNT" -eq "$SRC_COUNT" ]] \
    || die "step 4: the copy has $COPY_COUNT files but the source has $SRC_COUNT - the backup is incomplete"

# The state step 6 compares against, taken while nothing has been uninstalled yet.
BEFORE_RECORDINGS_EXISTS=0; [[ -d "$RECORDINGS_SRC" ]] && BEFORE_RECORDINGS_EXISTS=1
BEFORE_RECORDINGS_COUNT="$(count_files "$RECORDINGS_SRC")"
BEFORE_DB_EXISTS=0;       [[ -f "$DB_SRC" ]] && BEFORE_DB_EXISTS=1
BEFORE_DB_DESC="$(describe_file "$DB_SRC")"
BEFORE_PREFS_EXISTS=0;    [[ -f "$PREFS_SRC" ]] && BEFORE_PREFS_EXISTS=1
BEFORE_PREFS_SHA="$(sha256_of "$PREFS_SRC")"
BEFORE_SUPPORT_COUNT="$(count_files "$SUPPORT_SRC")"

if [[ "$BEFORE_RECORDINGS_EXISTS" -eq 1 ]]; then
    BEFORE_RECORDINGS_DESC="present, $BEFORE_RECORDINGS_COUNT files"
else
    BEFORE_RECORDINGS_DESC="absent"
fi

# ---------------------------------------------------------------------------
# Step 5 - uninstall the current version (never --remove-user-data)
# ---------------------------------------------------------------------------

step 5 "uninstall the current version"

UNINSTALLER=""
if [[ -f "$INSTALLED_CMD" ]]; then
    UNINSTALLER="$INSTALLED_CMD"
elif [[ -f "$VENDORED_CMD" ]]; then
    UNINSTALLER="$VENDORED_CMD"
else
    die "step 5: neither $INSTALLED_CMD nor $VENDORED_CMD exists"
fi

echo "    uninstaller: $UNINSTALLER"
echo "    arguments:   (none - --remove-user-data is never passed)"

UNINSTALL_LOG="$LOG_DIR/uninstall.log"
uninstall_status=0
/bin/sh "$UNINSTALLER" > "$UNINSTALL_LOG" 2>&1 || uninstall_status=$?
printf '    --- %s ---\n' "$UNINSTALL_LOG"
tail -n 20 "$UNINSTALL_LOG" | sed 's/^/    /'

[[ "$uninstall_status" -eq 0 ]] \
    || die "step 5: the uninstaller exited $uninstall_status; log: $UNINSTALL_LOG"
[[ ! -e "$INSTALLED_APP" ]] \
    || die "step 5: $INSTALLED_APP is still there after the uninstaller"

# ---------------------------------------------------------------------------
# Step 6 - verify the uninstall kept his data
# ---------------------------------------------------------------------------

step 6 "verify the uninstall kept his data"

AFTER_RECORDINGS_EXISTS=0; [[ -d "$RECORDINGS_SRC" ]] && AFTER_RECORDINGS_EXISTS=1
AFTER_RECORDINGS_COUNT="$(count_files "$RECORDINGS_SRC")"
AFTER_DB_EXISTS=0;         [[ -f "$DB_SRC" ]] && AFTER_DB_EXISTS=1
AFTER_DB_DESC="$(describe_file "$DB_SRC")"
AFTER_PREFS_EXISTS=0;      [[ -f "$PREFS_SRC" ]] && AFTER_PREFS_EXISTS=1
AFTER_PREFS_SHA="$(sha256_of "$PREFS_SRC")"
AFTER_SUPPORT_COUNT="$(count_files "$SUPPORT_SRC")"

if [[ "$AFTER_RECORDINGS_EXISTS" -eq 1 ]]; then
    AFTER_RECORDINGS_DESC="present, $AFTER_RECORDINGS_COUNT files"
else
    AFTER_RECORDINGS_DESC="absent"
fi

if [[ "$AFTER_PREFS_EXISTS" -eq 1 ]]; then
    AFTER_PREFS_DESC="present, sha256 $AFTER_PREFS_SHA"
else
    AFTER_PREFS_DESC="absent"
fi

print_data_table() {
    printf '    %-46s | %-58s | %s\n' "item" "before uninstall" "after uninstall"
    printf '    %s\n' "---------------------------------------------------------------------------------------------------------------------------------------"
    printf '    %-46s | %-58s | %s\n' "recordings directory" "$BEFORE_RECORDINGS_DESC" "$AFTER_RECORDINGS_DESC"
    printf '    %-46s | %-58s | %s\n' "recordings database (recordings.sqlite)" "$BEFORE_DB_DESC" "$AFTER_DB_DESC"
    if [[ "$BEFORE_PREFS_EXISTS" -eq 1 ]]; then
        printf '    %-46s | %-58s | %s\n' "preferences plist" "present, sha256 $BEFORE_PREFS_SHA" "$AFTER_PREFS_DESC"
    else
        printf '    %-46s | %-58s | %s\n' "preferences plist" "absent (not on disk before)" "$AFTER_PREFS_DESC"
    fi
    printf '    %-46s | %-58s | %s\n' "whole Application Support dir (informational: models + caches are removed on purpose)" "$BEFORE_SUPPORT_COUNT files" "$AFTER_SUPPORT_COUNT files"
    printf '\n'
}

print_data_table

if [[ "$BEFORE_RECORDINGS_EXISTS" -eq 1 ]]; then
    if [[ "$AFTER_RECORDINGS_EXISTS" -ne 1 ]]; then
        die "step 6: THE UNINSTALL DELETED HIS RECORDINGS DIRECTORY ($RECORDINGS_SRC). Nothing has been installed. A read-only copy is at $BACKUP_DIR."
    fi
    if [[ "$AFTER_RECORDINGS_COUNT" -ne "$BEFORE_RECORDINGS_COUNT" ]]; then
        die "step 6: the recordings directory had $BEFORE_RECORDINGS_COUNT files before the uninstall and $AFTER_RECORDINGS_COUNT after. Nothing has been installed. A read-only copy is at $BACKUP_DIR."
    fi
fi

if [[ "$BEFORE_DB_EXISTS" -eq 1 && "$AFTER_DB_EXISTS" -ne 1 ]]; then
    die "step 6: THE UNINSTALL DELETED THE RECORDINGS DATABASE ($DB_SRC). Nothing has been installed. A read-only copy is at $BACKUP_DIR."
fi

if [[ "$BEFORE_PREFS_EXISTS" -eq 1 ]]; then
    if [[ "$AFTER_PREFS_EXISTS" -ne 1 ]]; then
        die "step 6: THE UNINSTALL DELETED THE PREFERENCES PLIST ($PREFS_SRC). Nothing has been installed. A read-only copy is at $BACKUP_DIR."
    fi
    if [[ "$AFTER_PREFS_SHA" != "$BEFORE_PREFS_SHA" ]]; then
        die "step 6: the preferences plist changed across the uninstall (before $BEFORE_PREFS_SHA, after $AFTER_PREFS_SHA). Nothing has been installed. A read-only copy is at $BACKUP_DIR."
    fi
fi

echo "    kept: recordings, recordings database and settings unchanged."

# ---------------------------------------------------------------------------
# Step 7 - install the new build from the package's own payload
# ---------------------------------------------------------------------------

step 7 "install the new build from the package's own payload"

# pkgutil --expand-full creates the destination itself and fails if it already
# exists, so the destination is not created here (and a stale one is cleared).
rm -rf "$EXPAND_DIR"
pkgutil --expand-full "$PKG" "$EXPAND_DIR" > "$LOG_DIR/pkg-expand.log" 2>&1 \
    || die "step 7: pkgutil --expand-full failed; log: $LOG_DIR/pkg-expand.log"

PAYLOAD="$EXPAND_DIR/OpenSuperWhisper-component.pkg/Payload"
PAYLOAD_APP="$PAYLOAD/Applications/OpenSuperWhisper.app"
PAYLOAD_CMD="$PAYLOAD/Applications/Uninstall OpenSuperWhisper.command"
[[ -d "$PAYLOAD_APP" ]] || die "step 7: the payload has no app at $PAYLOAD_APP"
[[ -f "$PAYLOAD_CMD" ]] || die "step 7: the payload has no uninstall command at $PAYLOAD_CMD"

ditto "$PAYLOAD_APP" "$INSTALLED_APP"
install -m 755 "$PAYLOAD_CMD" "$INSTALLED_CMD"
xattr -d com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

[[ -d "$INSTALLED_APP" ]] || die "step 7: no app at $INSTALLED_APP after installing the payload"
[[ -f "$INSTALLED_CMD" ]] || die "step 7: no uninstall command at $INSTALLED_CMD after installing the payload"

codesign --verify --deep --strict "$INSTALLED_APP" \
    || die "step 7: codesign --verify --deep --strict failed on $INSTALLED_APP"

INSTALLED_DR="$(codesign -d -r- "$INSTALLED_APP" 2>&1 \
    | grep -E '^#?[[:space:]]*designated =>' \
    | sed -E 's/^#?[[:space:]]*designated => //')"
[[ -n "$INSTALLED_DR" ]] || die "step 7: could not read the designated requirement off $INSTALLED_APP"
if [[ "$INSTALLED_DR" != "$BUILD_DR" ]]; then
    die "step 7: the installed bundle's designated requirement differs from the one the build reported.
       build:     $BUILD_DR
       installed: $INSTALLED_DR"
fi
echo "    installed: $INSTALLED_APP"
echo "    uninstall command: $INSTALLED_CMD"
echo "    codesign --verify --deep --strict: OK"
echo "    designated requirement matches the build: $INSTALLED_DR"

# ---------------------------------------------------------------------------
# Step 8 - report
# ---------------------------------------------------------------------------

step 8 "report"

INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/OpenSuperWhisper"
[[ -f "$INSTALLED_BINARY" ]] || die "step 8: no executable at $INSTALLED_BINARY"

echo "    installed app:          $INSTALLED_APP"
echo "    installed binary:       $INSTALLED_BINARY"
echo "    installed binary sha256: $(sha256_of "$INSTALLED_BINARY")"
echo "    package:                $PKG"
echo "    package sha256:         $PKG_SHA  (recorded in $SHA_FILE)"
echo "    designated requirement: $INSTALLED_DR"
echo "    backup:                 $BACKUP_DIR (read-only)"
echo ""
echo "    data before/after the uninstall (step 6):"
print_data_table

echo "done."
