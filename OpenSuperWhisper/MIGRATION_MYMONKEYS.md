# Migrating our OpenSuperWhisper fork onto `my-monkeys/OpenSuperWhisper`

Status: discovery + plan. No app code changed by this document.
Audience: Evan (not a Swift dev) — goal is to **adopt my-monkeys conventions** and re-base our
customizations on top of their far-more-maintained fork.

This audit was done statically on a Linux VM (cannot compile SwiftUI). It leans on the fact that the
local working copy at `/tmp/OpenSuperWhisper` already has all three remotes fetched:
`origin` = Starmel (upstream), `fork` = EvanSchalton (ours), `monkeys` = my-monkeys.

---

## 0. Where we are today

| Fork | Role | Maturity (commits ahead of Starmel `master`) | Latest |
|------|------|----------------------------------------------|--------|
| `Starmel/OpenSuperWhisper` (`origin`) | original, unmaintained | baseline | — |
| `EvanSchalton/OpenSuperWhisper` (`fork`) | ours | **17** (master) / ~big on feature branch | local `feat/remote-temperature-prompt` |
| `my-monkeys/OpenSuperWhisper` (`monkeys`) | target | **357** | v0.9.2, 2026-06-29 (actively shipping) |

Our real work is **not all on `master`** — `master` only carries the RemoteEngine + remote-settings
work (9 files). The context-rules / transcript-metadata / source-capture features live on the current
branch `feat/remote-temperature-prompt`. The full delta vs Starmel is **16 files, ~1485 insertions, 5
new files** (see §2).

Decision (already made): **fork my-monkeys, then cherry-pick + adapt our features onto it**, embracing
their structure and conventions rather than the reverse.

Good news up front — the two forks are highly compatible:
- **Identical** `TranscriptionEngine` protocol (`isModelLoaded`, `engineName`, `initialize()`,
  `transcribeAudio(url:settings:)`, `cancelTranscription()`, `getSupportedLanguages()`).
- **Same** `AppPreferences` style: `@UserDefault` / `@OptionalUserDefault` property wrappers.
- **Same** engine-selection pattern: a string `AppPreferences.selectedEngine` switched in
  `TranscriptionService`.
- **Same** persistence stack: GRDB + the same `Recording`/`RecordingStore` shape and GRDB
  `DatabaseMigrator` pattern; **same** SPM deps (GRDB, KeyboardShortcuts).
- **Same** file layout (`Engines/`, `Indicator/`, `Models/`, `Utils/`, `Whis/`, `Onboarding/`).

So this is a *port onto a superset*, not a rewrite.

---

## 1. my-monkeys structure + conventions to adopt

**Build / project**
- Default branch: **`master`**. Xcode project (`OpenSuperWhisper.xcodeproj`) + SPM (`.swiftpm`,
  `Package.resolved`). Build via `./run.sh build` (see `.github/workflows/build.yml`); deps incl.
  `cmake libomp rust ruby`. Distribution via notarized `.dmg` + Homebrew cask
  `my-monkeys/tap/opensuperwhisper`, Sparkle auto-update (`appcast.xml`).
- Fastlane/Gemfile present; CLI mode (`CLI.swift`) for headless transcription.

**Module / file organization** (under `OpenSuperWhisper/`)
- `Engines/` — one file per engine, all conforming to `TranscriptionEngine`:
  `WhisperEngine`, `FluidAudioEngine` (Parakeet), `SenseVoiceEngine` (+`SenseVoiceModelManager`,
  `SherpaOnnx`), `GroqEngine`, plus `StreamingTranscriptionController` and an `EngineCapabilities`
  enum (static capability lookup keyed by engine id, so the UI can gate features without
  instantiating an engine).
- `Utils/` — small focused helpers: `Keychain`, `AppPreferences`, `LLMPostProcessor`,
  `TextInserter`, `SparkleUpdater`, `LanguageManager`, `PostRecordHook`, `Diag`, etc.
- `Models/` — `Recording` (GRDB), `CustomDictionary`, `RetentionPolicy`.
- `Indicator/` — `IndicatorWindow*` plus a full Notch / Dynamic-Island mode
  (`NotchShape`, `NotchMetrics`, `NotchTuning`).
- Settings is split into composable SwiftUI sections (e.g. `GroqSettingsSection.swift`,
  `SenseVoiceModelSection.swift`) bound to a shared `SettingsViewModel`.

**Code-style conventions**
- Heavy, intent-explaining doc comments on types/functions (often citing the upstream PR/issue #).
  Match this — it's the house style and our own files already do it.
- Engine ids are lowercase strings (`"whisper"`, `"fluidaudio"`, `"sensevoice"`, `"groq"`); add
  `"remote"` to this family.
- Capabilities (translation support, supported languages) are centralized in `EngineCapabilities`,
  not scattered in each engine — new engines must register there.
- Secrets go in **Keychain** (`Utils/Keychain.swift`, service `fr.my-monkey.opensuperwhisper`),
  exposed through a computed `AppPreferences` property — **not** raw UserDefaults. (Ours currently
  stores the remote API key in UserDefaults via `@OptionalUserDefault` — change this on port.)
- Localization via `Localizable.xcstrings` (EN/FR/DE/ES/IT/PT-BR). User-facing strings we add should
  be localizable, though English-only is acceptable for a first pass.

**How their Groq (OpenAI-compatible) remote engine works** — `Engines/GroqEngine.swift`
- `final class GroqEngine: TranscriptionEngine`. `isModelLoaded` = "a Groq API key exists".
- Hardcoded `endpoint = "https://api.groq.com/openai/v1/audio"`; models hardcoded
  `["whisper-large-v3-turbo", "whisper-large-v3"]`; `translatingModel = "whisper-large-v3"`.
- `transcribeAudio` builds a **multipart/form-data POST** to `<endpoint>/transcriptions` (or
  `/translations` when translate + full model). Fields: `file`, `model`, `response_format=json`, and
  `language` (skipped for `auto`/translate). Auth: `Authorization: Bearer <key>`. Decodes
  `{"text": ...}`; typed `GroqError` for 401 / api / network.
- API key read from `AppPreferences.shared.groqAPIKey` → **Keychain** (`groqAPIKey`); model from
  `groqModel` (UserDefault). Wired in `TranscriptionService` via
  `else if selectedEngine == "groq" { engine = GroqEngine() }`.
- Settings UI: `GroqSettingsSection.swift` — a `SettingsViewModel`-bound card listing the two models
  as rows (lock 🔒 until a key is entered, ✓ on the active one), a `SecureField` key editor popover
  ("Stored in your Keychain"), and a loud "audio is uploaded / not on-device" warning Label.
- Credits @Schreezer's upstream Starmel PR #64; reimplemented against this fork's protocol.

**Net:** their `GroqEngine` is essentially a *hardcoded special case* of what our `RemoteEngine`
already does generically. That makes the generalization in §4 natural.

---

## 2. Our customizations to port (inventory)

Source of truth: `git diff origin/master..feat/remote-temperature-prompt` (16 files; 5 new).
Five distinct features:

### F1 — RemoteEngine (self-hosted OpenAI-compatible transcription) — **the headline feature**
- **Files:** `Engines/RemoteEngine.swift` (NEW, 192 lines), `RemoteServerSettingsView.swift` (NEW,
  302 lines), `Utils/AppPreferences.swift` (remote keys), `Settings.swift`,
  `TranscriptionService.swift` (`selectedEngine == "remote"` wiring), `Onboarding/OnboardingView.swift`.
- **What it does:** talks to a configurable OpenAI-compatible server (our self-hosted **Engram**;
  also speaches / LiteLLM / Ollama-style). Configurable **base URL** (tolerant of trailing slash /
  `/v1`, defaults http:// for LAN), **model name**, **optional API key** (no `Authorization` header
  when empty → no-auth servers work), and a **configurable timeout** set on the
  `URLSessionConfiguration` (POST-body ignores `URLRequest.timeoutInterval`) with a "disabled = ~1yr"
  sentinel for slow server pipelines. Multipart POST to `<base>/v1/audio/transcriptions` with
  `response_format=json`, `model`, `language` (skip `auto`), `translate`, and the OpenAI-standard
  **`temperature`** + **`prompt`** (initial_prompt) — only sent when set. Tolerant response parsing
  (`text` / `result` / bare string). Progress callbacks. Settings panel can fetch `/v1/models` and
  cache them (`cachedRemoteModels`).
- **Migration risk: LOW.** Same protocol; coexists with their engines. Main work is *merging* with
  their `GroqEngine` rather than landing alongside it (§4), and moving the API key to Keychain.

### F2 — Context-aware model selection (per-app + per-site rules)
- **Files:** `AppContextModelRules.swift` (NEW, 143 lines), `ModelCatalog.swift` (NEW, 114 lines),
  `OpenSuperWhisperApp.swift` (menu-bar picker + prompts), `Settings.swift` (Advanced tab + help
  popovers), `AppPreferences.swift` (`appModelRules`, `contextAwareModelMode`).
- **What it does:** `ContextAwareModelMode` (`ask` / `auto` / `off`); `RecordingContext` (frontmost
  app + browser host captured at record-start / menu-open) with a "Just This Time" one-time override;
  `AppContextModelRules` persists `bundleID` or composite `bundleID|host` → `DictationModelOption`
  (JSON in UserDefaults). `ModelCatalog` is the cross-engine source of truth for available models
  (`whisper` + `fluidaudio`/parakeet + `remote`) and applies a selection by setting
  `selectedEngine` + the engine's model pref and calling `reloadEngine()`.
- **Migration risk: MEDIUM.** `ModelCatalog`/`DictationModelOption` enumerate the engine set —
  must be extended to monkeys' engines (`sensevoice`, and treat `groq` as a remote preset). Menu-bar
  + Settings UI must be re-integrated into their `SettingsViewModel`-based panels. Self-contained
  logic ports cleanly; the UI wiring is the effort.

### F3 — Transcript metadata + history UX
- **Files:** `Models/Recording.swift` (GRDB columns + migration), `ContentView.swift` (2-line
  layout, rerun-with-model dropdown), `TranscriptionQueue.swift`, `TranscriptionService.swift`.
- **What it does:** adds `sourceAppName` / `sourceWindowTitle` / `sourceURL` / `modelUsed` columns
  (all optional, nil-default → back-compatible) via a new GRDB migration; records **real audio
  duration**; shows the model used; "rerun with a specific model" without touching the default;
  2-line metadata row in the history list.
- **Migration risk: MEDIUM.** monkeys' `Recording` schema currently stops at `v2_add_status`
  (id/timestamp/fileName/transcription/duration/status/progress/sourceFileURL) — it does **not** have
  our metadata columns. Our migration must be re-authored as a **new migration version appended after
  theirs** (e.g. `v3_add_source_metadata`) so it composes with their migrator and any of their later
  migrations. Do not renumber/replace their migrations. `ContentView` has diverged most between
  forks (their history UI is richer) — expect manual re-application, not a clean cherry-pick.

### F4 — Source capture (where dictation happened)
- **Files:** `SourceCapture.swift` (NEW, 59 lines), `OpenSuperWhisper-Info.plist` (usage strings).
- **What it does:** focused-window title via Accessibility (`AXUIElementCopyAttributeValue`), active
  browser tab URL via per-bundle AppleScript (Chrome/Brave/Edge/Vivaldi/Arc/Safari), host
  normalization (strip `www.`). Feeds F2 (per-site rules) and F3 (metadata). Adds Info.plist usage
  strings (Apple Events / automation).
- **Migration risk: LOW.** Standalone enum, no deps on our other changes. Just add the file + merge
  the Info.plist usage-string keys (theirs already has many entitlements/usage strings — merge, don't
  overwrite).

### F5 — Indicator (recording bubble) tweaks
- **Files:** `Indicator/IndicatorWindow.swift`, `Indicator/IndicatorWindowManager.swift`.
- **What it does:** show the targeted app in the recording bubble; widen it so full app names fit;
  capture the targeted app when the menu opens.
- **Migration risk: HIGH (conflict-wise).** monkeys rewrote the indicator substantially (Notch /
  Dynamic-Island mode, `NotchShape`/`NotchMetrics`/`NotchTuning`, configurable position). Our diffs
  will **not** apply cleanly. Re-implement the "show target app + width" behavior on top of their
  indicator, or drop it if their newer indicator already addresses the need. Lowest priority.

**Other touched files:** `OpenSuperWhisperApp.swift` (menu-bar model picker — part of F2),
`Settings.swift` (host for F1/F2 panels), `AppPreferences.swift` (keys for F1/F2).

---

## 3. The plan — fork, then port in sequence

### Step A — Evan does the GitHub side (needs his creds; not doable from this VM)
1. On GitHub, **fork `my-monkeys/OpenSuperWhisper`** into `EvanSchalton/` (or re-point the existing
   `EvanSchalton/OpenSuperWhisper` — note our current fork's `origin` is Starmel, `fork` is ours,
   `monkeys` is the target; we'll make my-monkeys the new upstream).
2. Locally, create a fresh integration branch off `monkeys/master`:
   `git fetch monkeys && git switch -c port/onto-monkeys monkeys/master`.
   (Keep the existing `feat/*` branches as the reference source to port *from*.)

### Step B — port features onto `port/onto-monkeys`, lowest-risk first
Recommended order (each as its own PR/commit, matching monkeys' small-PR + doc-comment style):

1. **F4 SourceCapture** (LOW) — drop in `SourceCapture.swift`; merge Info.plist usage strings.
   Foundation for F2/F3; no UI.
2. **F1 RemoteEngine, merged with their Groq path** (LOW–MED) — see §4. Land the configurable
   remote engine, fold Groq into it as a preset, move keys to Keychain, register `"remote"` in
   `TranscriptionService` and `EngineCapabilities`, add the settings section in their
   `SettingsViewModel` style.
3. **F3 Recording metadata** (MED) — append a **new** GRDB migration after theirs; thread
   `modelUsed` + source fields through `TranscriptionService`/`TranscriptionQueue`; re-apply the
   2-line layout + rerun-with-model onto **their** `ContentView` (manual).
4. **F2 Context rules + ModelCatalog** (MED) — port `AppContextModelRules` + `RecordingContext`
   verbatim; extend `ModelCatalog`/`DictationModelOption` to cover `whisper`/`fluidaudio`/
   `sensevoice`/`remote` (+ Groq-as-remote); re-wire the menu-bar picker and Advanced-tab UI into
   their Settings.
5. **F5 Indicator tweaks** (HIGH conflict / LOW value) — last. Re-implement "show target app" on
   their Notch-capable indicator, or skip if redundant.

After each: build in Xcode on Evan's Mac (this VM can't). Keep commits scoped so their reviewers (and
ours) can follow.

### Step C — reconcile shared prefs/keys
- Our `selectedEngine == "remote"` slots into their engine string family with no schema clash.
- Verify no `AppPreferences` key-name collisions (both define `selectedEngine`, `temperature`,
  `initialPrompt`, `translateToEnglish` identically — reuse theirs, don't duplicate).
- Move `remoteServerAPIKey` from `@OptionalUserDefault` to a Keychain-backed computed property
  (mirror their `groqAPIKey`).

---

## 4. Generalizing their Groq engine into our configurable remote engine

Goal: **one** remote-transcription path that serves **both** Groq and our self-hosted Engram (and any
OpenAI-compatible server), instead of their hardcoded `GroqEngine` + our separate `RemoteEngine`.

Their `GroqEngine` and our `RemoteEngine` are the same shape; Groq is the special case where
base URL, model list, and key account are fixed. Plan:

1. **Adopt our `RemoteEngine` as the general engine** (it already does configurable URL/model/key +
   timeout + `temperature`/`prompt` + tolerant parsing + `/v1/models` discovery — a strict superset
   of `GroqEngine`). Register it under `selectedEngine == "remote"` in `TranscriptionService`.
2. **Model Groq as a built-in preset of the remote engine**, not a separate class. A preset supplies:
   - base URL `https://api.groq.com/openai` (our `transcriptionsEndpoint()` already appends `/v1/...`
     and tolerates the trailing segment),
   - the curated model list (`whisper-large-v3-turbo`, `whisper-large-v3`) instead of `/v1/models`,
   - the "uploads audio / not on-device" warning,
   - **Keychain-backed** key (account `groqAPIKey`, preserving their stored key so existing Groq
     users don't re-enter it),
   - translation behavior: only `whisper-large-v3` translates → keep this in `EngineCapabilities`
     (which already encodes exactly this rule via `supportsTranslation(engine:groqModel:)`). Map our
     engine's translate handling to use the `/translations` endpoint when the preset is Groq + full
     model, matching their current behavior. (Our generic engine sends `translate=true` as a form
     field — Engram-style servers honor that; for Groq, switch to the `/translations` path.)
3. **Settings UI:** generalize `GroqSettingsSection` into a remote-engine section with a **preset
   picker** (Custom / Engram / Groq). Selecting a preset prefills base URL + model list + key label +
   warning; "Custom" exposes the full URL/model/timeout fields we already have in
   `RemoteServerSettingsView`. Reuse their card/lock/✓ row visual language so it matches the other
   engines.
4. **Capabilities + languages:** add a `"remote"` case to `EngineCapabilities.supportsTranslation`
   and `supportedLanguages` (advertise `[]`/full list so the user's language choice is forwarded
   verbatim, as our engine does today; for the Groq preset, reuse their curated Groq language list).
5. **Keychain everywhere:** route both the Groq preset key and a custom-server key through Keychain
   (distinct accounts, e.g. `groqAPIKey` and `remoteServerAPIKey`).

Result: Groq becomes "the remote engine pointed at Groq with a fixed model list," Engram is "the
remote engine pointed at your server," and both share one engine, one settings section, one code path.

---

## 5. Open questions for Evan

1. **Keep Groq as a preset, or fully replace it with the generic remote engine?** Recommendation:
   keep it as a preset (preserves their UX, Keychain key, and the translate-model rule) — confirm.
2. **`selectedEngine` value:** keep our `"remote"` as a sibling of `"groq"`, or collapse Groq into
   `"remote"` + a preset field? (Affects migration of existing Groq users' `selectedEngine`.)
3. **Repo strategy:** new fork of my-monkeys, or re-point the existing `EvanSchalton/OpenSuperWhisper`
   to track `monkeys/master` as upstream? Either works; the latter keeps issue/PR history.
4. **Upstream-ability:** do we want the generalized remote engine to be PR-able **back to
   my-monkeys** (so they maintain it)? If yes, the Engram specifics must stay behind the generic
   "Custom server" preset and the doc-comment/credit conventions must be followed strictly.
5. **Indicator (F5):** does monkeys' newer Notch/position indicator already cover the "show target
   app" need, letting us drop F5 entirely?
6. **Localization:** English-only for our new strings on first pass, or wire them into
   `Localizable.xcstrings` from the start?
7. **Engram translate semantics:** does the Engram server honor a `translate=true` form field, or
   should the generic engine always use OpenAI's `/translations` endpoint for translation (matching
   Groq)? Confirm so the generalized engine handles translation consistently.

---

## Appendix — key file references

| Concern | my-monkeys | ours (`feat/remote-temperature-prompt`) |
|--------|------------|------------------------------------------|
| Engine protocol | `Engines/TranscriptionEngine.swift` (+`EngineCapabilities`) | `Engines/TranscriptionEngine.swift` (identical) |
| Remote/cloud engine | `Engines/GroqEngine.swift` | `Engines/RemoteEngine.swift` |
| Remote settings UI | `GroqSettingsSection.swift` | `RemoteServerSettingsView.swift` |
| Secrets | `Utils/Keychain.swift` + `groqAPIKey` computed | `@OptionalUserDefault remoteServerAPIKey` (move to Keychain) |
| Prefs | `Utils/AppPreferences.swift` (`@UserDefault`) | same pattern (+remote/context keys) |
| Engine wiring | `TranscriptionService.swift` switch on `selectedEngine` | same; adds `"remote"` |
| Model catalog | (none — per-engine) | `ModelCatalog.swift` / `DictationModelOption` |
| Context rules | (none) | `AppContextModelRules.swift` |
| Source capture | (none) | `SourceCapture.swift` |
| Recording schema | `Models/Recording.swift` (through `v2_add_status`) | adds `sourceAppName/WindowTitle/URL`, `modelUsed` |
| Indicator | `Indicator/` + Notch (`NotchShape/Metrics/Tuning`) | `Indicator/IndicatorWindow*` tweaks |
