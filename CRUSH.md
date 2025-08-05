# CRUSH.md

Purpose: Quick reference for agents working in OpenSuperWhisper (macOS 14+, arm64 Swift/SwiftUI + whisper.cpp).

Build/Run
- Initial setup: git submodule update --init --recursive; brew install cmake; gem install xcpretty
- Dev: ./run.sh build  # build only
- Dev run: ./run.sh    # build and run app
- Manual: cmake -G Xcode -B libwhisper/build -S libwhisper; xcodebuild -scheme OpenSuperWhisper -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build

Test
- All: xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS,arch=arm64'
- Target: xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests
- Single file: xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/TextImprovementServiceTests
- Single case: xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperTests/TextImprovementServiceTests/testEnhancesText
- UI tests: xcodebuild test -scheme OpenSuperWhisper -only-testing:OpenSuperWhisperUITests

Lint/Format
- SwiftFormat if present in PATH: swiftformat .
- SwiftLint if present: swiftlint
- Xcode format: xcodebuild -scheme OpenSuperWhisper build CODE_SIGNING_ALLOWED=NO | xcpretty

Code Style
- Imports: Foundation, SwiftUI, AVFoundation, AppKit only where needed; prefer explicit imports; no wildcard
- Formatting: 2-space indent; max line ~120; trailing commas allowed in multiline; keep modifiers and attributes on separate lines
- Types: Prefer strong types; avoid Any; use optional only when truly absent; favor structs over classes unless reference semantics required
- Concurrency: Use async/await; isolate UI on @MainActor; avoid unstructured Task where not needed; cancel tasks on teardown
- Errors: Use throws, propagate with try; avoid fatalError; log with os_log or print in tests only; never log secrets
- Naming: lowerCamelCase for vars/funcs, UpperCamelCase for types; enums singular; protocols end with Provider/Managing where appropriate
- Dependency boundaries: use STTProviderFactory for STT backends; keep Whisper interop in Whis/*; avoid cross-module leakage
- Resource management: clean up temp files; manage OpaquePointer lifecycles; no retain cycles (use [weak self])
- UI: MVVM; keep business logic out of Views; use @Published for observable state; accessibility IDs for UI tests

Release
- Notarized build: ./notarize_app.sh "Developer ID Application: NAME (TEAM_ID)"
- Full release: ./make_release.sh <version> "Developer ID Application: NAME (TEAM_ID)" <GITHUB_TOKEN>

Notes
- Default model bundled: ggml-tiny.en.bin; additional models in Application Support via WhisperModelManager
- No Cursor/Copilot rules found; if added later, mirror key rules here.
