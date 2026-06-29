# Releasing OpenSuperWhisper

> **The complete, canonical guide is [`PUBLISHING.md`](./PUBLISHING.md)** (stable + beta channels,
> toolchain gotchas, verification, troubleshooting, key inventory). This file is a short summary kept
> for reference.

The app is distributed as a **notarized Developer ID** build, published as a GitHub release DMG
and installable via Homebrew.

## One-time setup (already done)

- **Developer ID Application** certificate for team `5C67TFSJ2B` is in the login keychain
  (`security find-identity -v -p codesigning` lists it).
- **Notarization** uses an App Store Connect API key stored as the notarytool keychain profile
  `osw-notary` (the `.p8`, key, CSR and cert live in `~/.osw-signing/`, chmod 700).
- Bundle id: `fr.my-monkey.opensuperwhisper`.

## Architectures

Each release ships **two** notarized DMGs — there is no universal binary:

| DMG | Arch | Engines | Sparkle feed |
|---|---|---|---|
| `OpenSuperWhisper-arm64-$VERSION.dmg`  | Apple Silicon | Whisper · Parakeet · SenseVoice | `appcast.xml` |
| `OpenSuperWhisper-x86_64-$VERSION.dmg` | Intel         | Whisper · Parakeet             | `appcast-x86_64.xml` |

SenseVoice is excluded from x86_64 because its onnxruntime ships arm64-only (the engine is behind
`#if arch(arm64)`; the x86_64 build strips the onnxruntime dylib and points `SUFeedURL` at the
Intel feed). `notarize_app.sh` builds the universal native deps (autocorrect pinned to deployment
target 14.0; a fat libomp via `Scripts/fetch-libomp-universal.sh`) so either slice can link.

## Cut a release

```sh
# 1. bump MARKETING_VERSION (+ CURRENT_PROJECT_VERSION) in the Xcode project, commit.
VERSION=0.5.0

# 2. build → sign → notarize → staple → DMG, ONCE PER ARCH  (~12 min each)
./notarize_app.sh "Developer ID Application: Maxim Costa (5C67TFSJ2B)" arm64
./notarize_app.sh "Developer ID Application: Maxim Costa (5C67TFSJ2B)" x86_64
#    → ./OpenSuperWhisper-arm64.dmg  and  ./OpenSuperWhisper-x86_64.dmg

# 3. version the names + grab the hashes
for a in arm64 x86_64; do
  mv "OpenSuperWhisper-$a.dmg" "OpenSuperWhisper-$a-$VERSION.dmg"
  shasum -a 256 "OpenSuperWhisper-$a-$VERSION.dmg"
done

# 4. publish the release with BOTH DMGs attached
gh release create "v$VERSION" --repo my-monkeys/OpenSuperWhisper \
  "OpenSuperWhisper-arm64-$VERSION.dmg" "OpenSuperWhisper-x86_64-$VERSION.dmg" \
  --title "v$VERSION — …" --notes-file notes.md
```

Verify each DMG before announcing: `xcrun stapler validate OpenSuperWhisper-<arch>-$VERSION.dmg`
and, after mounting, `spctl -a -vvv -t exec /Volumes/OpenSuperWhisper/OpenSuperWhisper.app` should
say `accepted` / `source=Notarized Developer ID`.

## Update the Homebrew cask

The cask lives in the **`my-monkeys/homebrew-tap`** repo at `Casks/opensuperwhisper.rb`. It uses
an `arch arm: "arm64", intel: "x86_64"` stanza with per-arch `on_arm`/`on_intel` `sha256` blocks and
a `#{arch}` URL, so `brew` fetches the matching DMG. After a release, bump `version` and **both**
`sha256` values (from step 3) and push.

```sh
brew install --cask my-monkeys/tap/opensuperwhisper
```

> Use the full `my-monkeys/tap/` path — the bare `opensuperwhisper` resolves to the original
> (unmaintained) cask in homebrew-cask, not this fork.

## Auto-update (Sparkle)

The app embeds **Sparkle**. The menu-bar **"Check for Updates…"** runs Sparkle's verified
in-place download + install; the Settings → Updates tab still shows the GitHub release-note history.

- Feed: `SUFeedURL` in Info.plist → `appcast.xml` at the repo root (served via
  `https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast.xml`).
- Signing key: an EdDSA keypair; the **public** key is `SUPublicEDKey` in Info.plist, the **private**
  key lives in the login keychain (generated once via Sparkle's `generate_keys`).

**Per release**, after building the notarized DMG (and before/with publishing it), append an item to
`appcast.xml`:

```sh
# sign the DMG with the EdDSA private key (from the keychain)
/path/to/Sparkle/bin/sign_update OpenSuperWhisper-$VERSION.dmg
#   → sparkle:edSignature="…" length="…"
```

Sign **both** DMGs and add an `<item>` to the matching feed — the arm64 DMG → `appcast.xml`, the
x86_64 DMG → **`appcast-x86_64.xml`** (each build's `SUFeedURL` points at its own feed, so the two
arches never offer each other's downloads). Each item carries the new `<sparkle:shortVersionString>`,
`<sparkle:version>` (= `CURRENT_PROJECT_VERSION`), the release-tag `<link>`, and an `<enclosure>`
whose `url` is that arch's GitHub release DMG, with the `sparkle:edSignature` and `length` from
`sign_update`. Commit both feeds to `master`. (The Sparkle CLI tools come from the
[Sparkle release tarball](https://github.com/sparkle-project/Sparkle/releases).)
