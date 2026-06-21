# Spec — Live transcription, sub-phase A: live caption in the indicator (Parakeet)

**Date** : 2026-06-21 · **Branch** : `feat/live-transcription`

## 1. Goal
Show the dictation **as you speak**: while recording, a live caption builds up in the
recording indicator (volatile words dimmed, confirmed words solid). On release, the final
text is post-processed and inserted as today. Read-only caption (sub-phase A); live
*insertion into the field* is sub-phase B (separate, builds on this).

## 2. Decisions
- **Engine**: FluidAudio's `StreamingAsrManager` (Parakeet). It exposes `volatileTranscript`,
  `confirmedTranscript`, a `transcriptionUpdates: AsyncStream<StreamingTranscriptionUpdate>`,
  `start(source:.microphone)`, `streamAudio`, `finish() -> String`, `configureVocabularyBoosting`.
- **Engine scope**: live works on **Parakeet only**. On Whisper we keep the current
  file-based flow (Whisper streaming would require maintaining a forked whisper.cpp — out of
  scope, bad for fork health).
- **Opt-in**: new `liveTranscriptionEnabled` pref (default off), effective only when the
  selected engine is `fluidaudio`.
- **Display**: in the existing recording indicator (chosen UX), not a new panel.

## 3. Architecture
```
record start ──▶ if liveTranscriptionEnabled && engine == fluidaudio:
                    StreamingTranscriptionController.start()
                      ├─ StreamingAsrManager.start(source:.microphone)   (own AVAudioEngine tap)
                      ├─ configureVocabularyBoosting(CustomDictionary.boostTerms)  (if dict on)
                      └─ Task: for await update in transcriptionUpdates { publish liveTranscript }
                 (the WAV AVAudioRecorder still runs in parallel → playback / history intact)
indicator ◀────── @Published liveTranscript (confirmed + " " + volatile)
record stop  ──▶ StreamingTranscriptionController.finish() -> String (final)
                 → apply post-processing (CustomDictionary.apply, autocorrect, space-after, …)
                 → insert (existing ClipboardUtil path) + hide indicator
fallback     ──▶ live off / Whisper / model not loaded / start error → current file-based flow
```

Two mic consumers run at once (StreamingAsrManager's tap + the WAV `AVAudioRecorder`). PR #147
demonstrates this parallel pattern works; verified at build/smoke time.

## 4. Components (files)
- **`OpenSuperWhisper/Engines/StreamingTranscriptionController.swift`** (new): owns the
  `StreamingAsrManager`; `start(settings:)`, `finish() async -> String?`, `cancel()`;
  `@MainActor @Published var liveTranscript: String`; wires vocabulary boosting; isolates all
  FluidAudio-streaming details behind a small interface.
- **`OpenSuperWhisper/Indicator/IndicatorWindow.swift`**: a live-caption view — render the
  controller's `liveTranscript` (confirmed solid, trailing volatile dimmed); grow/scroll/clip
  for long text; shown during recording when live mode is active.
- **Recording hook** (`IndicatorViewModel` / `AudioRecorder` start & stop paths): start/stop the
  streaming controller alongside the WAV recorder; on stop use the streamed text (post-processed)
  instead of a file pass, with fallback.
- **`OpenSuperWhisper/Utils/AppPreferences.swift`**: `liveTranscriptionEnabled` (default false).
- **`OpenSuperWhisper/Settings.swift`**: a toggle (with a note: Parakeet only).
- **Tests** (`OpenSuperWhisperTests`): pure text-assembly logic (e.g. composing
  confirmed+volatile, applying post-processing to the final string). The real streaming/mic path
  is environment-dependent → voice smoke by Maxim.

## 5. Error handling / fallback
- StreamingAsrManager fails to start (no model, mic busy, etc.) → log, fall back to the existing
  file-based transcription for that recording (no user-visible breakage).
- If `finish()` yields empty → the existing "No speech detected" handling applies.
- Cancel path stops the stream and discards.

## 6. Testing & verification
- Build green (`./run.sh build`).
- Unit suite green (no regression; new tests for text assembly).
- **Voice smoke (Maxim)**: with Parakeet + live on, dictate → caption builds in the indicator in
  real time; on stop the final text inserts correctly (and respects the custom dictionary).
  Verify Whisper still works (file-based, unchanged). Verify graceful fallback.

## 7. Non-goals (sub-phase A)
- Live insertion into the focused field (= sub-phase B).
- Whisper streaming / the #147 forked-whisper.cpp approach.
- Indicator-position configurability (#125 part 2, separate).
