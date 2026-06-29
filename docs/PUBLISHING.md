# Publishing OpenSuperWhisper

The complete, no-shortcuts reference for shipping a build. This supersedes the older
`RELEASING.md` / `release_build.md` (kept as short pointers). If a step here disagrees with a
script, the **script wins** — fix this doc.

The app is distributed as a **notarized Developer ID** build (not the App Store), published as a
GitHub release DMG, auto-updated via **Sparkle**, and installable via **Homebrew**.

---

## 0. TL;DR — two channels

| | **Stable** (e.g. `0.9.3`) | **Beta** (e.g. `0.9.3-beta.3`) |
|---|---|---|
| Arches built | arm64 **and** x86_64 | arm64 only |
| GitHub release | normal release (`Latest`) | **pre-release** |
| Tag | `v0.9.3` | `v0.9.3-beta.3` |
| Sparkle appcast | **yes** — both feeds get a new `<item>` | **no** — never touched |
| Homebrew cask | **yes** — bump version + both sha256 | **no** |
| Who gets it | everyone (auto-update + brew) | only people who manually download the pre-release DMG |

The split exists so stable users are **never** auto-offered a beta: betas live only as a
GitHub pre-release asset; the appcast and the cask only ever point at stable DMGs.

---

## 1. Distribution model

Each **stable** release ships **two** notarized DMGs — there is no universal binary:

| DMG | Arch | Engines | Sparkle feed |
|---|---|---|---|
| `OpenSuperWhisper-arm64-$VERSION.dmg`  | Apple Silicon | Whisper · Parakeet · SenseVoice | `appcast.xml` |
| `OpenSuperWhisper-x86_64-$VERSION.dmg` | Intel         | Whisper · Parakeet             | `appcast-x86_64.xml` |

SenseVoice is excluded from x86_64 because its `onnxruntime` ships **arm64-only** (the engine is
behind `#if arch(arm64)`; the x86_64 build strips the onnxruntime dylib post-build and rewrites its
`SUFeedURL` to the Intel feed). Each arch's `SUFeedURL` points at its own appcast, so the two slices
**never offer each other's downloads**.

`notarize_app.sh` builds the universal native deps so either slice can link:
- **autocorrect** (Rust) → universal, pinned to deployment target 14.0.
- **libomp** → fat dylib from `vendor/libomp-universal.dylib`.
- **libwhisper** → built with generic CPU flags (`GGML_NATIVE=OFF`) for both arches.
- **onnxruntime** → arm64-only; copied in for the embed phase, stripped from the x86_64 app after build.

---

## 2. Versioning

Two numbers live in `OpenSuperWhisper.xcodeproj/project.pbxproj`:

- **`MARKETING_VERSION`** → the human version, e.g. `0.9.3`. Maps to `CFBundleShortVersionString`
  and `<sparkle:shortVersionString>`.
- **`CURRENT_PROJECT_VERSION`** → the **build number**, a monotonically increasing integer. Maps to
  `CFBundleVersion` and **`<sparkle:version>`**. **This is the number Sparkle compares** to decide
  whether an update is newer — it MUST strictly increase every release (stable *and* beta).

Rules:
- **Every** release (including each beta) bumps `CURRENT_PROJECT_VERSION` by 1.
- A beta only bumps the build number; `MARKETING_VERSION` already carries the target, with the
  pre-release suffix living **only in the git tag / release title** (`v0.9.3-beta.3`), never in the
  plist.
- Because betas aren't in the appcast, the feed's `<sparkle:version>` jumps over the beta build
  numbers (e.g. `26` for 0.9.2 → `29` for 0.9.3) — that's fine, it just has to increase.

Current state (read from the project): `MARKETING_VERSION = 0.9.3`, `CURRENT_PROJECT_VERSION = 29`.
Build-number history: `0.9.0=24`, `0.9.1=25`, `0.9.2=26`, `beta.1=27`, `beta.2=28`, `beta.3=29`.

---

## 3. One-time setup (already done — inventory)

Everything below already exists on Maxim's Mac. Listed so a release can be reproduced / recovered.

| Thing | Value / location |
|---|---|
| Bundle id | `fr.my-monkey.opensuperwhisper` |
| Team id | `5C67TFSJ2B` |
| **Release** signing identity | `Developer ID Application: Maxim Costa (5C67TFSJ2B)` (login keychain) |
| **Dev** signing identity (NOT for release) | `Apple Development: Maxim Costa (7U4ZZUR2PN)` — pinned in `.osw-codesign-identity`, used by `run.sh` / `Scripts/dev-codesign.sh` to keep TCC grants across dev rebuilds |
| Notarization creds | App Store Connect API key as the **notarytool keychain profile `osw-notary`**; the `.p8` + key + CSR + cert live in `~/.osw-signing/` (chmod 700) |
| Sparkle EdDSA **public** key | `SUPublicEDKey` in `OpenSuperWhisper/OpenSuperWhisper-Info.plist` = `ECQpCBVVumUKoBjgcDPSlmllYiWlSAUFGh5WycBhCA0=` |
| Sparkle EdDSA **private** key | in the login keychain (created once via Sparkle's `generate_keys`); `sign_update` reads it automatically. Verify with `…/bin/generate_keys -p` → must print the public key above |
| Sparkle CLI tools | `SourcePackages/artifacts/sparkle/Sparkle/bin/` (`sign_update`, `generate_keys`, `generate_appcast`) — present after Swift packages resolve |
| arm64 feed | `https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast.xml` |
| x86_64 feed | `https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast-x86_64.xml` |
| Homebrew tap | repo `my-monkeys/homebrew-tap`, cask `Casks/opensuperwhisper.rb`; cloned locally at `/opt/homebrew/Library/Taps/my-monkeys/homebrew-tap` |

If notarization ever says the profile is missing, recreate it with:
```sh
xcrun notarytool store-credentials osw-notary \
  --key ~/.osw-signing/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
```

---

## 4. Prerequisites each time (and the toolchain gotchas, up front)

- **`xcodebuild` needs the FULL Xcode.** `notarize_app.sh` calls `xcodebuild` — make sure the active
  developer dir is Xcode (`xcode-select -p` → `…/Xcode.app/…`, not CommandLineTools).
- **`git` / `gh` / `brew` may refuse with "Xcode license not agreed".** When that happens, prefix
  just those commands with `DEVELOPER_DIR=/Library/Developer/CommandLineTools` (CLT has no license
  gate). Do **not** run `xcodebuild` under CLT. (Or accept once: `sudo xcodebuild -license accept`.)
- **Homebrew name collision.** A cask named `opensuperwhisper` also exists in `homebrew/cask` (the
  unmaintained Starmel original). **Always** use the fully-qualified `my-monkeys/tap/opensuperwhisper`
  for install/upgrade, or you'll pull the wrong app.
- **macOS 26/27 beta toolchain bug.** The beta `ld` links the Rust autocorrect dylib with a
  mis-aligned LINKEDIT string pool that it then rejects for the arm64 slice. Workaround: a known-good
  prebuilt `vendor/libautocorrect_swift.dylib` is vendored; `notarize_app.sh` uses it automatically
  when present (`if [ -f vendor/libautocorrect_swift.dylib ]`). **Delete that vendored file once the
  toolchain is fixed** so the build goes back to compiling autocorrect from source.
- **Build deps** (already installed): `cmake`, `libomp`, `rust`/`cargo`, and `xcpretty`
  (`gem install xcpretty`). CI installs them via `brew install cmake libomp rust`.
- **`log` is shadowed by a zsh function** in this shell — use `/usr/bin/log` if you need unified
  logging while diagnosing.

---

## 5. Build & notarize — what `notarize_app.sh` does

```sh
./notarize_app.sh "Developer ID Application: Maxim Costa (5C67TFSJ2B)" arm64
./notarize_app.sh "Developer ID Application: Maxim Costa (5C67TFSJ2B)" x86_64   # stable only
```

One invocation, per arch (~12 min each), runs end to end:
1. `Scripts/fetch-sherpa.sh` + `Scripts/fetch-libomp-universal.sh` (native deps).
2. Build libwhisper (both arches, generic CPU), autocorrect (universal or vendored), copy
   libomp/onnxruntime, codesign each dylib with `--timestamp`.
3. `xcodebuild -scheme OpenSuperWhisper -configuration Release` for the requested `ARCHS`, manual
   signing, hardened runtime.
4. **x86_64 only:** strip `libonnxruntime*.dylib` from the app, rewrite `SUFeedURL` → Intel feed.
5. Re-sign Sparkle's nested helpers (`Downloader.xpc`, `Installer.xpc`, `Autoupdate`, `Updater.app`,
   then the framework), then re-seal the whole app with hardened runtime + entitlements.
6. Zip → `notarytool submit --wait` → `stapler staple` the app.
7. Build the DMG with `hdiutil` (app + `/Applications` symlink), codesign the DMG, notarize + staple
   **the DMG too**.

Output: `./OpenSuperWhisper-arm64.dmg` (and `./OpenSuperWhisper-x86_64.dmg`).

> The DMG produced is unversioned (`OpenSuperWhisper-<arch>.dmg`); you rename it with the version in
> the next step.

---

## 6. Stable release — full procedure

```sh
VERSION=0.9.3
TAG="v$VERSION"
ID="Developer ID Application: Maxim Costa (5C67TFSJ2B)"
SPARKLE_VER=29   # = CURRENT_PROJECT_VERSION; must be > the previous feed entry (26)
```

### 6.1 Bump the version, commit
Set `MARKETING_VERSION` (and bump `CURRENT_PROJECT_VERSION`) in `project.pbxproj`. If the build
number is already at the target (e.g. betas got us to 29), keep it; otherwise bump. Commit.
```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -am "chore: release $VERSION (build $SPARKLE_VER)"
```

### 6.2 Build + notarize both arches
```sh
./notarize_app.sh "$ID" arm64
./notarize_app.sh "$ID" x86_64
```

### 6.3 Version the names + capture hash & length (needed for cask + appcast)
```sh
for a in arm64 x86_64; do
  mv "OpenSuperWhisper-$a.dmg" "OpenSuperWhisper-$a-$VERSION.dmg"
  echo "== $a =="
  shasum -a 256 "OpenSuperWhisper-$a-$VERSION.dmg"     # → Homebrew sha256
  stat -f%z   "OpenSuperWhisper-$a-$VERSION.dmg"        # → appcast enclosure length (bytes)
done
```

### 6.4 Sign each DMG with the Sparkle EdDSA key
```sh
SIGN=./SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
$SIGN "OpenSuperWhisper-arm64-$VERSION.dmg"     # → sparkle:edSignature="…" length="…"
$SIGN "OpenSuperWhisper-x86_64-$VERSION.dmg"
```
`sign_update` reads the private key from the keychain — no key path needed. It prints both the
`edSignature` and the `length`; use those verbatim in the appcast item.

### 6.5 Publish the GitHub release with BOTH DMGs
```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
gh release create "$TAG" --repo my-monkeys/OpenSuperWhisper \
  "OpenSuperWhisper-arm64-$VERSION.dmg" "OpenSuperWhisper-x86_64-$VERSION.dmg" \
  --title "$TAG — <headline>" --notes-file notes.md
```
(`--latest` is implied for a normal release. Write `notes.md` first — see §11 for tone.)

### 6.6 Append an `<item>` to BOTH appcasts
arm64 DMG → `appcast.xml`; x86_64 DMG → `appcast-x86_64.xml`. Insert as the **first** `<item>` in
each `<channel>`. Template (fill the 4 per-arch values: url, edSignature, length, pubDate):
```xml
    <item>
      <title>0.9.3</title>
      <link>https://github.com/my-monkeys/OpenSuperWhisper/releases/tag/v0.9.3</link>
      <sparkle:version>29</sparkle:version>
      <sparkle:shortVersionString>0.9.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>Mon, 29 Jun 2026 18:30:00 +0000</pubDate>
      <enclosure
        url="https://github.com/my-monkeys/OpenSuperWhisper/releases/download/v0.9.3/OpenSuperWhisper-arm64-0.9.3.dmg"
        sparkle:edSignature="<from sign_update on the arm64 dmg>"
        length="<bytes of the arm64 dmg>"
        type="application/octet-stream" />
    </item>
```
For `appcast-x86_64.xml`, the same item but the enclosure `url` ends in `-x86_64-` and the
`edSignature`/`length` come from the **x86_64** DMG. `<sparkle:version>` and
`<sparkle:shortVersionString>` are identical across both feeds. Commit both feeds to `master`
(Sparkle serves them raw from `master`, so the update goes live the moment you push):
```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -am "chore: appcast $VERSION (both arches)"
DEVELOPER_DIR=/Library/Developer/CommandLineTools git push origin master
```

### 6.7 Update the Homebrew cask
Edit `/opt/homebrew/Library/Taps/my-monkeys/homebrew-tap/Casks/opensuperwhisper.rb` (or the repo on
GitHub). Bump `version` and **both** `sha256` (arm64 → `on_arm`, x86_64 → `on_intel`), from §6.3.
Current shape:
```ruby
cask "opensuperwhisper" do
  arch arm: "arm64", intel: "x86_64"
  version "0.9.3"
  on_arm   { sha256 "<arm64 sha256>" }
  on_intel { sha256 "<x86_64 sha256>" }
  url "https://github.com/my-monkeys/OpenSuperWhisper/releases/download/v#{version}/OpenSuperWhisper-#{arch}-#{version}.dmg",
      verified: "github.com/my-monkeys/OpenSuperWhisper/"
  name "OpenSuperWhisper"
  desc "macOS dictation with local Whisper/Parakeet transcription"
  homepage "https://github.com/my-monkeys/OpenSuperWhisper"
  depends_on macos: :sonoma
  app "OpenSuperWhisper.app"
  binary "#{appdir}/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper", target: "opensuperwhisper"
  zap trash: [
    "~/Library/Application Support/fr.my-monkey.opensuperwhisper",
    "~/Library/Preferences/fr.my-monkey.opensuperwhisper.plist",
    "~/Library/Caches/fr.my-monkey.opensuperwhisper",
    "~/Library/Application Support/FluidAudio",
  ]
end
```
Commit + push the tap repo. Then `brew update && brew upgrade my-monkeys/tap/opensuperwhisper`.

### 6.8 Verify (see §10) and announce (see §11).

---

## 7. Beta / pre-release — procedure

Lighter: arm64 only, GitHub **pre-release**, **no** appcast, **no** Homebrew.

```sh
VERSION=0.9.3
BETA=3
TAG="v$VERSION-beta.$BETA"
ID="Developer ID Application: Maxim Costa (5C67TFSJ2B)"
```
1. Bump `CURRENT_PROJECT_VERSION` (+ keep `MARKETING_VERSION = $VERSION`), commit:
   `chore: bump build to 29 (0.9.3-beta.3)`.
2. Build arm64 only: `./notarize_app.sh "$ID" arm64`.
3. Rename: `mv OpenSuperWhisper-arm64.dmg "OpenSuperWhisper-arm64-$VERSION-beta.$BETA.dmg"`.
4. Publish as **pre-release** (`--prerelease`), arm64 DMG only:
   ```sh
   DEVELOPER_DIR=/Library/Developer/CommandLineTools \
   gh release create "$TAG" --repo my-monkeys/OpenSuperWhisper --prerelease \
     "OpenSuperWhisper-arm64-$VERSION-beta.$BETA.dmg" \
     --title "$TAG — <what to test>" --notes-file beta-notes.md
   ```
5. **Do NOT** touch `appcast.xml`, `appcast-x86_64.xml`, or the cask.
6. To replace a bad beta build, delete + recreate the tag:
   `gh release delete "$TAG" --cleanup-tag --yes` then re-create.

> Why arm64-only for betas: Intel testing happens on the dedicated Intel Mac via the stable channel;
> betas are for fast iteration on the main (Apple Silicon) machine.

---

## 8. Sparkle appcast — notes

- Feeds are **hand-curated** XML at the repo root, served raw from `master`. There's no generated
  feed step — newest `<item>` goes first; keep the full history.
- `generate_appcast` (in the Sparkle bin dir) exists but is **not** used here; we sign each DMG with
  `sign_update` and paste the values, so the feed URLs stay GitHub-release URLs (not a local dir).
- An update is offered when a feed's top `<sparkle:version>` is **greater** than the installed
  `CFBundleVersion`. Equal or lower = nothing offered. That's the whole gate — get the build number
  right.
- The in-app **"Check for Updates…"** (menu bar) runs Sparkle's verified download+install; the
  Settings → Updates tab shows the GitHub release-note history.

---

## 9. Verification checklist (before announcing)

Per DMG:
```sh
xcrun stapler validate "OpenSuperWhisper-<arch>-$VERSION.dmg"      # → "The validate action worked!"
hdiutil attach "OpenSuperWhisper-<arch>-$VERSION.dmg"
spctl -a -vvv -t exec "/Volumes/OpenSuperWhisper/OpenSuperWhisper.app"
#   → accepted ; source=Notarized Developer ID
hdiutil detach "/Volumes/OpenSuperWhisper"
```
End to end:
- `gh release view "$TAG" --repo my-monkeys/OpenSuperWhisper` — both DMGs attached (stable) / arm64 only (beta).
- Stable: `curl -sI <enclosure url>` returns 302→200 (asset reachable for Sparkle).
- Stable: `brew update && brew upgrade my-monkeys/tap/opensuperwhisper` installs the new version.
- Sparkle: from the previous stable, menu-bar **Check for Updates…** offers the new version and
  installs it (the real auto-update path — worth doing once per stable).

---

## 10. Post-release: website, feedback, README

- **Website** `opensuperwhisper.com` (repo `my-monkeys/opensuperwhisper-site`, Astro, deployed via
  monkey). Update the download/version if it's pinned, and the changelog/benchmark if relevant. It
  also hosts the **feedback form** (`#feedback`) that POSTs to `https://git.my-monkey.fr/api/feedback`
  → lands in the monkey dashboard (Vitrine → Retours). (ntfy push for those is **not** configured yet
  — see the feedback-intake memory.)
- **In-app Feedback tab** (Settings → Feedback) links to: GitHub Issues (technical), the website form
  (everyone), and the Releases page (betas).
- **Readme.md** has a "Beta testing — we need you" section pointing at Releases + Issues + the form.
- **Attribution:** public-facing text is **My-Monkey** / the collective — never a real name (see the
  `public-attribution-no-real-name` memory).
- **Commits / tags:** author is the `MaximCosta` handle, **no AI/Claude mention** anywhere in commit
  messages (see the `commit-attribution-no-ai` memory).

Release-note tone (from the blog/site voice): plain, honest, what changed and what to test — not
marketing. A 🍌 at the end is on-brand but optional.

---

## 11. Troubleshooting / known gotchas

| Symptom | Cause → fix |
|---|---|
| `xcodebuild` works but `git`/`gh`/`brew` say "Xcode license not agreed" | beta Xcode is active → prefix those with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, or `sudo xcodebuild -license accept` once |
| Build fails: "mis-aligned LINKEDIT string pool" (arm64) | beta-toolchain ld bug → ensure `vendor/libautocorrect_swift.dylib` is present (script uses it); remove it after the toolchain is fixed |
| `brew upgrade opensuperwhisper` pulls the wrong/old app | name collision with homebrew/cask → use `my-monkeys/tap/opensuperwhisper` |
| Notarization: "no profile named osw-notary" | recreate with `notarytool store-credentials` (§3) |
| `sign_update: command not found` | Swift packages not resolved → run `./run.sh build` once (resolves `SourcePackages/`), or `xcodebuild -resolvePackageDependencies` |
| Sparkle doesn't offer the update | top `<sparkle:version>` ≤ installed `CFBundleVersion`, or feeds not pushed to `master`, or you edited the wrong feed for the arch |
| App relaunch leaves two instances / stale grants | `pkill -9 OpenSuperWhisper` before relaunching; TCC grants carry over between **same Developer-ID** builds, so a fresh install keeps Accessibility/Input-Monitoring |
| Need to inspect app logs | `defaults write fr.my-monkey.opensuperwhisper diagnosticLogging -bool YES`, then `/usr/bin/log stream --predicate 'subsystem == "fr.my-monkey.opensuperwhisper"'` (note `/usr/bin/log`, `log` is shadowed) |

---

## 12. File & key reference

| Path | Role |
|---|---|
| `notarize_app.sh` | the real build → sign → notarize → staple → DMG pipeline (per arch) |
| `run.sh` | dev build & run (Debug, ad-hoc/dev-signed); CI uses `./run.sh build` |
| `Scripts/dev-codesign.sh` | re-signs the dev build with the pinned `.osw-codesign-identity` for TCC stability |
| `.osw-codesign-identity` | the **dev** signing identity (Apple Development) — **not** for release |
| `appcast.xml` / `appcast-x86_64.xml` | Sparkle feeds (arm64 / Intel), served raw from `master` |
| `OpenSuperWhisper/OpenSuperWhisper-Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `CFBundleVersion`, etc. |
| `vendor/libautocorrect_swift.dylib` | beta-toolchain workaround (delete when ld is fixed) |
| `vendor/libomp-universal.dylib`, `vendor/onnxruntime/` | native deps |
| `.github/workflows/build.yml` | CI **build check only** (push/PR/manual) — does NOT notarize or release |
| `~/.osw-signing/` | App Store Connect API key material (chmod 700) |
| `SourcePackages/artifacts/sparkle/Sparkle/bin/` | `sign_update`, `generate_keys`, `generate_appcast` |

---

## Appendix — `make_release.sh` is LEGACY, do not use

`make_release.sh` is the original Starmel script. It is **wrong for this fork**: it targets
`Starmel/OpenSuperWhisper`, uploads a single `OpenSuperWhisper.dmg` (no per-arch naming), builds
arm64 only, and prints an outdated arm64-only cask. Keep the manual flow above. (Left in the repo for
historical reference; safe to delete.)
