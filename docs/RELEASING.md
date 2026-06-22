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

## Auto-update (Sparkle) — not yet wired

The in-app "Check for Updates" (Settings → Updates, and the menu-bar item) compares the running
version against the latest GitHub release and links to it. Full in-place auto-update via Sparkle
would build on the Developer-ID signing above; not implemented yet.
