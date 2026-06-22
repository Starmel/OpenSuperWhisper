# Releasing OpenSuperWhisper

The app is distributed as a **notarized Developer ID** build, published as a GitHub release DMG
and installable via Homebrew.

## One-time setup (already done)

- **Developer ID Application** certificate for team `5C67TFSJ2B` is in the login keychain
  (`security find-identity -v -p codesigning` lists it).
- **Notarization** uses an App Store Connect API key stored as the notarytool keychain profile
  `osw-notary` (the `.p8`, key, CSR and cert live in `~/.osw-signing/`, chmod 700).
- Bundle id: `fr.my-monkey.opensuperwhisper`.

## Cut a release

```sh
# 1. bump MARKETING_VERSION (+ CURRENT_PROJECT_VERSION) in the Xcode project, commit.

# 2. build → sign (hardened runtime) → notarize → staple → DMG  (~7 min)
./notarize_app.sh "Developer ID Application: Maxim Costa (5C67TFSJ2B)"
#    → produces ./OpenSuperWhisper.dmg (notarized + stapled)

# 3. name it per the version + grab the hash
VERSION=0.3.0
cp OpenSuperWhisper.dmg "OpenSuperWhisper-$VERSION.dmg"
shasum -a 256 "OpenSuperWhisper-$VERSION.dmg"

# 4. publish the release with the DMG attached
gh release create "v$VERSION" --repo my-monkeys/OpenSuperWhisper \
  "OpenSuperWhisper-$VERSION.dmg" --title "v$VERSION — …" --notes-file notes.md
```

Verify the DMG before announcing: `xcrun stapler validate OpenSuperWhisper-$VERSION.dmg` and,
after mounting, `spctl -a -vvv -t exec /Volumes/OpenSuperWhisper/OpenSuperWhisper.app` should say
`accepted` / `source=Notarized Developer ID`.

## Update the Homebrew cask

The cask lives in the **`my-monkeys/homebrew-tap`** repo at `Casks/opensuperwhisper.rb`. After a
release, bump `version` and `sha256` (the value from step 3) and push.

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

Add an `<item>` to `appcast.xml` with the new `<sparkle:shortVersionString>`, `<sparkle:version>`
(= `CURRENT_PROJECT_VERSION`), the release-tag `<link>`, and an `<enclosure>` whose `url` is the
GitHub release DMG, with the `sparkle:edSignature` and `length` from `sign_update`. Commit
`appcast.xml` to `master` so the feed updates. (The Sparkle CLI tools come from the
[Sparkle release tarball](https://github.com/sparkle-project/Sparkle/releases).)
