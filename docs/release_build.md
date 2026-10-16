## Release build

The artifact users install is `OpenSuperWhisper-<version>.pkg`: the app bundle, a
double-clickable `Uninstall OpenSuperWhisper.command`, the two models a fresh install needs to
dictate and to rewrite at all, and the installer receipt that uninstall relies on. Both
inference engines (whisper.cpp and llama.cpp) are linked into the app, so a release build is a
native build plus one `xcodebuild` — there is no server process to ship.

### What the package contains

| Payload path | What it is | Size |
| --- | --- | --- |
| `/Applications/OpenSuperWhisper.app` | the app, engines included | ~107 MB |
| `/Applications/Uninstall OpenSuperWhisper.command` | `packaging/uninstall.sh`, byte for byte | 10 KB |
| the same receipt, `ru.starmel.OpenSuperWhisper` | so `pkgutil` and the uninstaller agree what the package owns | — |

The package is ~88 MB compressed and carries no model weights: the speech model (1.62 GB), the
English transform weights (462 MB) and the fallback 1.5B (986 MB) are downloaded by the app
itself, on demand, from the URLs and pinned digests it already has
(`OpenSuperWhisper/Settings.swift` for the speech model, `TransformModelManager.swift` for the
weights), into the app's own directory under the user's `~/Library/Application Support`. Nothing
is shipped that would be re-downloaded or re-shipped by every update. The 5 GB 8B an earlier
build offered is not downloaded any more either: no job resolved to it once the transform became
English-only, so its catalogue entry was removed and with it the only way Settings had to show and
delete that file.

Nothing in the payload writes into a user's home directory. The recordings, the transcriptions
database, the settings and the models are all created by the app after install, which is what
lets an uninstall keep the first three and remove the rest.

### Prerequisites

    git submodule update --init --recursive
    brew install cmake rust ruby
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

`DEVELOPER_DIR` matters: `Scripts/build-native.sh` and `xcodebuild` both need the Xcode
toolchain, and with only the Command Line Tools selected every build stops at
`xcode-select: error: tool 'xcodebuild' requires Xcode`.

For a distributable build you also need a **Developer ID Application** identity (the app
and its nested code), a **Developer ID Installer** identity (the package) and a
`notarytool` keychain profile. Without them the same scripts still build the app and the
package, unsigned — see [Signing](#signing) below.

### Model weights are not part of a build

The package carries none. The app downloads what it needs on first use, from the URLs and pinned
digests it already has — `OpenSuperWhisper/Settings.swift` for the speech model
(`ggml-large-v3-turbo.bin`, 1.62 GB, `sha256 1fc70f77…`) and `TransformModelManager.swift` for the
transform weights: the English backend (`s1-mini-q4_k_m.gguf`, 462 MB, `sha256 3b41ebe2…`) and the
floor every English transform falls back to while it is absent
(`qwen2.5-1.5b-instruct-q4_k_m.gguf`, 986 MB, `sha256 1adf0b11…`) — into
`~/Library/Application Support/ru.starmel.OpenSuperWhisper/`. There is nothing to place before a
build, and a release ships no weights that the next release would ship again.

The third engine's weights are a download of their own, in `Qwen3ASRModelManager.swift`: Qwen3-ASR
is two GGUF files that the engine needs together (`Qwen3-ASR-1.7B-Q8_0.gguf`, 2.17 GB,
`sha256 58e22d05…`, and its audio projector `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`, 356 MB,
`sha256 46c1d533…`), which the Model tab shows, downloads, verifies and removes like any other row.
They land in the app's own directory next to the others
(`~/Library/Application Support/ru.starmel.OpenSuperWhisper/qwen3-asr-models/`), and an uninstall
that lists the downloaded models removes them too. Selecting the engine without them fails the
load with the file to fetch; nothing falls back to whisper.

Because the app verifies what it downloads against those digests (`TransformRuntime` refuses a
transform model whose digest does not match), the digests in the Swift files are the whole
contract: a file of the right name and the wrong bytes is not usable, and no model may be taken
from another application's data directory.

### One command

    ./make_release.sh <version> "<Developer ID Application: … (TEAM_ID)>" [github-token]

It bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, runs `notarize_app.sh`, then
tags the release, uploads `OpenSuperWhisper-<version>.pkg` (and, when `swifty-dmg` is
installed, the optional cask DMG) to the GitHub release, and prints the Homebrew cask
stanza that matches the artifacts. There is nothing to fetch first: the package is the app and
the uninstall command.

### The same steps by hand

    Scripts/build-native.sh Release

    CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_PANIC=abort \
    cargo build -p autocorrect-swift --release --target aarch64-apple-darwin \
      --manifest-path=libautocorrect/Cargo.toml
    cp libautocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib \
      build/libautocorrect_swift.dylib
    install_name_tool -id "@rpath/libautocorrect_swift.dylib" build/libautocorrect_swift.dylib

    xcodebuild -scheme OpenSuperWhisper -configuration Release -jobs 8 \
      -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
      -skipPackagePluginValidation -skipMacroValidation build

    packaging/build-pkg.sh --version <version> \
      --app build/Build/Products/Release/OpenSuperWhisper.app \
      --out "OpenSuperWhisper-<version>.pkg" \
      [--sign "<Developer ID Installer: …>" --notarize <keychain-profile>]

The last step packages the app and `packaging/uninstall.sh`; it has nothing else to find.

`Scripts/build-native.sh Release` builds llama.cpp (which owns the single ggml the app
links) and installs its ggml package, then configures whisper.cpp against that package
with `WHISPER_USE_SYSTEM_GGML=ON`. The app's Xcode project references both vendored
projects, so the Release configuration of each is built by the `xcodebuild` above.

`notarize_app.sh <identity>` is exactly this order plus signing, notarization and
stapling; it writes `OpenSuperWhisper-<version>.pkg` next to the checkout.

### Verify the packaging contract

    Scripts/verify-packaging.sh --app build/Build/Products/Release/OpenSuperWhisper.app

It runs the cycle, not the steps: a scratch install (from a package's own extracted payload when
one is built, and from an equivalent hand-built tree otherwise) → assert the app and the uninstall
command are there → uninstall → assert the app, the uninstall command, the downloaded models, the
caches and the receipt are gone and the recordings, the transcriptions and the settings are still
there → install again → assert a complete app and the user's data from before. It also checks
uninstall twice, uninstall with the app deleted by hand, `--remove-user-data` as the only thing
that takes the recordings, a model copy an earlier package left under `/Library` being removed,
`--help`'s wording, that no removal names a path outside the install root, and the built package's
payload: app, uninstall command, receipt id, preinstall hook, no stray AppleDouble files, no
weights, nothing in `/Library`, nothing in a home directory, and the app's own copy of the
uninstaller identical to `packaging/uninstall.sh`.

The scratch trees make it rootless and safe: everything goes through `OSW_INSTALL_ROOT`, so
`/Applications`, `/Library` and the real home directory are never touched.

`build-pkg.sh` also refuses to build from an app whose `Contents/Resources/uninstall.sh` is not
the current `packaging/uninstall.sh`. Xcode copies that script in at build time, so an app built
before a change to the uninstaller carries the old path list — the one that deleted the
recordings. Rebuild the app, then package it.

### Uninstalling

Uninstall is path-granular, because one `rm -rf` over the app's Application Support directory is
what took the recordings, the transcriptions and the settings along with the models:

| Removed without options | Kept without options | Removed only by `--remove-user-data` |
| --- | --- | --- |
| `/Applications/OpenSuperWhisper.app` | `~/Library/Application Support/ru.starmel.OpenSuperWhisper/recordings/` | the recordings directory |
| `/Applications/Uninstall OpenSuperWhisper.command` | `recordings.sqlite` next to it | the transcriptions database |
| the models the app downloaded into its own directory | `~/Library/Preferences/ru.starmel.OpenSuperWhisper.plist` | the settings |
| model copies an earlier package left in `/Library/Application Support/ru.starmel.OpenSuperWhisper/Models/`, if any | | |
| caches, HTTP storage, saved state, application scripts | | |
| crash reports and diagnostic reports named after the app | | |
| the installer receipt (`pkgutil --forget`) | | |

`uninstall.sh --help` lists exactly this, and the in-app confirmation sheet shows the same two
lists. The uninstaller is idempotent: twice, and after the app was deleted by hand. It never
touches `~/models`, `/opt/homebrew` or another application's data.

### Signing

What ends up inside the package is the signature `build-pkg.sh` reports when it runs. The
designated requirement is the part that matters:

    codesign -d -r- path/to/OpenSuperWhisper.app

An ad-hoc build (no identity) reports `designated => cdhash H"…"`, which changes on every
build; macOS keys Accessibility and Microphone grants in TCC against that requirement, so a
rebuilt app silently loses them. A certificate-signed build reports

    designated => identifier "ru.starmel.OpenSuperWhisper" and certificate leaf = H"…"

which survives rebuilds signed with the same identity. `build-pkg.sh` prints this line for
the app it packages, and refuses to call a cdhash-only build distributable.

Package signing and notarization are parameterised, not baked in:

    OSW_SIGN_IDENTITY="Developer ID Installer: … (TEAM_ID)" \
    OSW_NOTARY_PROFILE=<keychain-profile> \
    packaging/build-pkg.sh --version <version>

With neither set, the package is built unsigned and `pkgutil --check-signature` says so.
