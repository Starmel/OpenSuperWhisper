#!/bin/zsh

# The familiar entry point, now an alias for the signed build path.
#
# This script used to run xcodebuild itself, and that is what produced the
# layout which cannot hold a permission grant:
#
#   * CODE_SIGNING_ALLOWED=NO, with ENABLE_DEBUG_DYLIB left at its Debug
#     default, put the target's code in Contents/MacOS/OpenSuperWhisper.debug.dylib
#     behind a ~40 KB stub executable and left the bundle linker-signed, whose
#     designated requirement is `cdhash H"..."`. That is the binary TCC judges,
#     and the stub is not the app.
#   * macOS stores the Accessibility grant against that requirement, and this
#     script rebuilds before every launch, so a grant made for one launch never
#     matched the next binary. tccd says exactly that when it refuses:
#
#       Update Access Record: kTCCServiceAccessibility for
#       ru.starmel.OpenSuperWhisper to Allowed (System Set)
#       matchesCodeRequirement:]: SecStaticCodeCheckValidity() static code
#       (0x7b9f1bc300) from ru.starmel.OpenSuperWhisper : identifier
#       "ru.starmel.OpenSuperWhisper" and certificate leaf =
#       H"32266bcc51546f68f9347324bd3c81d853fde5a4"; status: -67050
#
# Scripts/dev-run.sh builds the single-binary layout and signs it with a stable
# identity, so the grant survives rebuilds. This script stays because ./run.sh
# is the entry point the Readme and everyone's muscle memory use.
#
# Usage:
#   ./run.sh         - build, sign, then run the app
#   ./run.sh build   - build and sign only
#   ./run.sh --help  - the options Scripts/dev-run.sh accepts

exec "$(dirname "$0")/Scripts/dev-run.sh" "$@"
