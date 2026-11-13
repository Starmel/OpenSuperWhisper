#!/bin/sh
#
# Uninstall OpenSuperWhisper.
#
# Two entry points, one implementation:
#
#   * Settings -> Advanced -> Uninstall OpenSuperWhisper..., or the same item in
#     the menu-bar menu. The app copies this script to a temporary file, starts
#     it with `--wait-pid <its own pid>` and quits. The script waits for that
#     process to exit before it removes anything.
#   * `/Applications/Uninstall OpenSuperWhisper.command`, shipped by the
#     installer, for when the app is already gone from /Applications.
#
# One path used to stand for six different kinds of thing. `rm -rf` on the
# Application Support directory took the recordings, the transcriptions database
# and the settings out together with the models, so an uninstall that was meant
# to remove an app destroyed the captain's dictation history as well --
# unrecoverably, because nothing went to the Trash. The list is path-granular
# now, and each path is one kind of thing:
#
#   removed by default
#       the app; the uninstall command; any model copies in
#       /Library/Application Support/<bundle id>/Models (an earlier package put
#       weights there; this one has the app download them instead, but the
#       directory is the app's own and a stale GB must not be left behind); the
#       models the app downloaded into its own directory; caches, HTTP storage,
#       saved state and application scripts; OS leftovers named after the app;
#       and the installer receipt.
#   kept by default
#       the recordings, the transcriptions database and the settings -- the part
#       of the app's directory that is the user's rather than the installer's.
#   --remove-user-data
#       removes the kept list too. Nothing else removes it.
#
# Idempotent by construction: every step tolerates absence, so running it twice
# -- or after deleting the app by hand -- is harmless.
#
# Nothing outside the list below is touched. In particular this never removes
# ~/models (the developer's own copy of the model files), /opt/homebrew (where a
# user-installed llama.cpp lives), or any other application's data.
#
# Testing: OSW_INSTALL_ROOT prefixes every absolute path (default "/"), so the
# whole path list can be exercised against a scratch tree. Everything that needs
# the real machine -- quitting the app, cfprefsd, the installer receipt, TCC --
# runs only when the root is "/", so a probe can never disturb the live system.

set -u

BUNDLE_ID="ru.starmel.OpenSuperWhisper"
APP_NAME="OpenSuperWhisper"

ROOT="${OSW_INSTALL_ROOT:-/}"
WAIT_PID=""
RESET_PERMISSIONS=0
REMOVE_USER_DATA=0
SELF_DELETE=0
QUIET=0

usage() {
    cat <<'EOF'
Uninstall OpenSuperWhisper.

Usage: uninstall.sh [options]

Removed without any option:
  the app, the uninstall command, any model copies in
  /Library/Application Support/ru.starmel.OpenSuperWhisper/Models (an earlier
  package installed some there; this one has the app download models instead),
  the models the app downloaded for itself, its caches and window state, and the
  installer receipt.

Kept without any option:
  your recordings, the transcriptions database and your settings. Uninstalling
  the app is not supposed to throw away your dictation history.

  --remove-user-data     also remove the recordings, the transcriptions
                         database and the settings -- everything the app wrote
                         under your home directory. Without this flag they are
                         kept, and a later install finds them again.
  --wait-pid <pid>       wait for that process to exit before removing anything
                         (used by the in-app uninstall action)
  --reset-permissions    also reset the microphone/accessibility grants
  --self-delete          remove this script when done (the in-app action runs a
                         temporary copy of it)
  --quiet                say nothing
  -h, --help             this text

Environment:
  OSW_INSTALL_ROOT       prefix every path with this directory (default "/").
                         For testing the path list against a scratch tree.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remove-user-data)
            REMOVE_USER_DATA=1
            shift
            ;;
        --wait-pid)
            WAIT_PID="${2:-}"
            shift 2
            ;;
        --reset-permissions)
            RESET_PERMISSIONS=1
            shift
            ;;
        --self-delete)
            SELF_DELETE=1
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "uninstall: unknown argument: $1" >&2
            echo "Try --help." >&2
            exit 2
            ;;
    esac
done

say() {
    [ "$QUIET" -eq 1 ] || echo "$1"
}

IS_REAL_ROOT=0
if [ "$ROOT" = "/" ]; then
    IS_REAL_ROOT=1
fi

APP="$ROOT/Applications/$APP_NAME.app"
UNINSTALL_COMMAND="$ROOT/Applications/Uninstall $APP_NAME.command"
SUPPORT_DIR="$ROOT$HOME/Library/Application Support/$BUNDLE_ID"
SHIPPED_MODELS_DIR="$ROOT/Library/Application Support/$BUNDLE_ID/Models"
SHIPPED_SUPPORT_DIR="$ROOT/Library/Application Support/$BUNDLE_ID"
DOWNLOADED_WHISPER_DIR="$SUPPORT_DIR/whisper-models"
DOWNLOADED_TRANSFORM_DIR="$SUPPORT_DIR/transform-models"
DOWNLOADED_QWEN3ASR_DIR="$SUPPORT_DIR/qwen3-asr-models"
CACHES_DIR="$ROOT$HOME/Library/Caches/$BUNDLE_ID"
HTTP_STORAGES_DIR="$ROOT$HOME/Library/HTTPStorages/$BUNDLE_ID"
SAVED_STATE_DIR="$ROOT$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
APP_SCRIPTS_DIR="$ROOT$HOME/Library/Application Scripts/$BUNDLE_ID"
PREFS_PLIST="$ROOT$HOME/Library/Preferences/$BUNDLE_ID.plist"
CRASH_PLIST_DIR="$ROOT$HOME/Library/Application Support/CrashReporter"
DIAGNOSTIC_REPORTS_DIR="$ROOT$HOME/Library/Logs/DiagnosticReports"
TEMP_RECORDINGS_DIR="$ROOT${TMPDIR:-/tmp}/temp_recordings"

# 1. Let the app finish quitting. The in-app action passes its own pid, because
#    an app cannot delete the bundle it is running from.
if [ -n "$WAIT_PID" ]; then
    waited=0
    while kill -0 "$WAIT_PID" 2>/dev/null; do
        [ "$waited" -ge 600 ] && break
        sleep 0.1
        waited=$((waited + 1))
    done
fi

# 2. Quit a copy that is still running (the .command entry point).
if [ "$IS_REAL_ROOT" -eq 1 ]; then
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1
    pkill -x "$APP_NAME" >/dev/null 2>&1
    waited=0
    while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
        [ "$waited" -ge 40 ] && break
        sleep 0.25
        waited=$((waited + 1))
    done
fi

# 3. The app, the models the package installed, and the package's own uninstall
#    command. All of it is owned by root after a .pkg install, so a plain user
#    cannot always remove it; that case asks for administrator authorisation
#    once, for the paths together. The .command and in-app entry points both
#    land here.
rm -rf "$APP"
rm -rf "$SHIPPED_MODELS_DIR"
rm -f "$UNINSTALL_COMMAND"
if [ "$IS_REAL_ROOT" -eq 1 ]; then
    if [ -e "$APP" ] || [ -e "$SHIPPED_MODELS_DIR" ] || [ -e "$UNINSTALL_COMMAND" ]; then
        say "Removing the app, the installed models and the uninstall command needs administrator authorisation."
        osascript -e "do shell script \"rm -rf '$APP' '$SHIPPED_MODELS_DIR' '$UNINSTALL_COMMAND'\" with administrator privileges" >/dev/null 2>&1
    fi
fi

# 4. The models the app downloaded for itself, next to the user's own files.
#    The shipped copies are read-only to the app and live under /Library (step
#    3), so these directories only ever hold downloads.
rm -rf "$DOWNLOADED_WHISPER_DIR"
rm -rf "$DOWNLOADED_TRANSFORM_DIR"
rm -rf "$DOWNLOADED_QWEN3ASR_DIR"

# 5. Caches, HTTP storage, saved window state and the app's own scripts: all of
#    it is rebuilt on the next launch, none of it is the user's data.
rm -rf "$CACHES_DIR"
rm -rf "$HTTP_STORAGES_DIR"
rm -rf "$SAVED_STATE_DIR"
rm -rf "$APP_SCRIPTS_DIR"

# 6. The user's own data -- recordings, the transcriptions database, settings --
#    only when asked for by name. Everything step 4 and step 5 already took is
#    the installer's or the app's; what is left here is the captain's.
if [ "$REMOVE_USER_DATA" -eq 1 ]; then
    rm -rf "$SUPPORT_DIR"
    rm -f "$PREFS_PLIST"

    if [ "$IS_REAL_ROOT" -eq 1 ]; then
        defaults delete "$BUNDLE_ID" >/dev/null 2>&1
        killall cfprefsd >/dev/null 2>&1
    fi
fi

# 7. OS leftovers named after the app, and the app's transient working files.
rm -f "$CRASH_PLIST_DIR/$APP_NAME"_*.plist
rm -f "$DIAGNOSTIC_REPORTS_DIR/$APP_NAME"-*.ips
rm -rf "$TEMP_RECORDINGS_DIR"

# 8. Directories the installer created for the models, if the uninstall left
#    them empty. `rmdir` refuses anything that still holds something, which is
#    the point: it can only tidy up, never delete.
rmdir "$SHIPPED_MODELS_DIR" 2>/dev/null
rmdir "$SHIPPED_SUPPORT_DIR" 2>/dev/null

# 9. The installer receipt, so `pkgutil --pkg-info` agrees the app is gone and a
#    later install is a clean first install.
if [ "$IS_REAL_ROOT" -eq 1 ]; then
    pkgutil --forget "$BUNDLE_ID" >/dev/null 2>&1

    # 10. Optional: the microphone/accessibility/input-monitoring grants. Off by
    #     default, because re-prompting on the next install is worse than
    #     leaving a stale grant behind.
    if [ "$RESET_PERMISSIONS" -eq 1 ]; then
        tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1
    fi
fi

say "OpenSuperWhisper has been removed."
say "Removed: $APP"
say "Removed: $SHIPPED_MODELS_DIR (model copies an earlier package installed for the app, if any)"
say "Removed: $DOWNLOADED_WHISPER_DIR, $DOWNLOADED_TRANSFORM_DIR and $DOWNLOADED_QWEN3ASR_DIR (downloaded models)"
say "Removed: caches, HTTP storage, saved state and the installer receipt"
if [ "$REMOVE_USER_DATA" -eq 1 ]; then
    say "Removed: $SUPPORT_DIR (recordings, transcriptions and settings)"
    say "Removed: $PREFS_PLIST"
else
    say "Kept: $SUPPORT_DIR (recordings, transcriptions and settings)"
    say "      run this again with --remove-user-data to remove those too."
fi
if [ "$IS_REAL_ROOT" -eq 1 ]; then
    say "Left alone: ~/models, /opt/homebrew and every other application's data."
fi

# 11. The in-app action runs a temporary copy of this script; drop it.
if [ "$SELF_DELETE" -eq 1 ]; then
    rm -f "$0"
fi

# The only failure worth reporting is a bundle that is still there afterwards.
if [ -e "$APP" ]; then
    say "Could not remove $APP."
    exit 1
fi

exit 0
