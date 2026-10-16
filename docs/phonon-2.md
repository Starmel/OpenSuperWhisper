# Phonon-2 integration notes

## Upstream pins and licences

The optional Phonon-2 engine is pinned to primary upstream artifacts rather
than a moving branch:

- [FermionResearch/Phonon-2-CoreML](https://huggingface.co/FermionResearch/Phonon-2-CoreML)
  revision `1143812fd4236522232a8c33e3115f0577e3cd7d`, manifest `3.0`.
- [fermionresearch/phonon-coreml 1.1.2](https://github.com/fermionresearch/phonon-coreml/tree/1.1.2),
  commit `bf59e574639b060e30ee1a3f9c0e003fed5744c8`.
- Model weights: CC BY 4.0. Swift runtime: Apache 2.0.

The model is downloaded only after the user requests it. Every file is checked
for its pinned length and SHA-256 before the version directory is activated.
The exact file manifest is in `THIRD_PARTY_NOTICES.md`; required attribution and
NOTICE text are also copied into the app as `Phonon2-NOTICE.txt`.

The Swift runtime sources and universal macOS decoder archive are vendored at
the exact 1.1.2 release because Xcode cannot build the upstream binary target
alongside FluidAudio: both binary XCFrameworks emit the same generic
`include/module.modulemap` output. The vendored `libPhononTDT.a` was verified
byte-for-byte against the macOS universal archive in the primary 1.1.2 tag; its
SHA-256 is `22fe6f7b949a4a56b4538f418b9b6142d6488e903a79eee9ad6bd8aca62930e5`.
`Vendor/phonon-coreml-1.1.2/UPSTREAM_REVISION` records the tagged source commit,
upstream archive path, and digest.

## Runtime architecture

The main app keeps its macOS 14 deployment target. Phonon is exposed only on an
Apple-silicon Mac running macOS 15 or later and executes in an embedded macOS 15
XPC service. That service imports and calls `PhononCoreML.Transcriber` directly,
with `.cpuAndNeuralEngine` compute units; there is no Python environment, CLI,
network transcription, or bundled model.

Live dictation sends mono 16 kHz samples across XPC as one `Data` buffer and
uses `Transcriber.transcribe(_:)`. Imported and queued durable audio sends its
existing URL and uses `Transcriber.transcribe(url:)`. The service eagerly loads
the 15-second function, which serves short inputs and the runtime's long-audio
windows. On the M5 benchmark, loading other palettes in the background delayed
first queued audio through ANE compilation contention, so background loading is
deliberately disabled for this configuration.

Selection remains persisted as `phonon`. If the platform is unsupported or the
model is missing, corrupt, or cannot prepare, the service reports the condition
and temporarily falls back to the configured local Whisper model without
changing the saved Phonon selection. Deleting Phonon removes both the downloaded
version directory and the runtime's content-addressed compiled cache.

## Reproduced pre-change defects

| Trigger | Masking condition | Visible symptom |
| --- | --- | --- |
| Persist/select an unknown engine value such as `phonon` | Engine construction used a broad final `else` branch | Whisper loaded successfully, hiding the unsupported selection. |
| Add a PCM-capable engine other than `WhisperEngine` | Direct PCM dispatch used `as? WhisperEngine` instead of an engine capability | Live audio silently fell back to the temporary-file URL route. |
| Trigger recording with no microphone while an engine is still loading | The busy check ran before the cached microphone-availability guard | The indicator showed `busy` instead of the actionable `no microphone` state. |

Engine selection is now exhaustive and unknown values fail explicitly. Direct
PCM and progress are expressed as engine capabilities, preserving the existing
Whisper and Parakeet behavior while allowing Phonon to use samples directly.
The recording trigger now checks microphone availability before engine busy
state; the check is cached and does not add a CoreAudio round-trip.

## M5 local benchmark

Measured on an Apple M5 MacBook Pro with 16 GB RAM and macOS 26.2. All engines
used the same 5.000-second English PCM clip and 97.106-second English fixture.
Phonon ran through the real app selection, direct-PCM, embedded XPC, and URL
paths. The current Whisper fast tier on this installation was
`ggml-large-v3-turbo.bin`. Times are wall-clock seconds. Peak memory is the Mach
physical-footprint peak. Each engine ran in a separately launched XCTest app
host, verified by distinct worker PIDs in the raw report. Phonon's value comes
from its fresh XPC helper; Parakeet and Whisper values come from their respective
fresh app hosts, so no earlier engine can contaminate a lifetime high-water mark.

| Measurement | Phonon-2 | Parakeet v3 | Whisper large-v3-turbo |
| --- | ---: | ---: | ---: |
| Fresh-process model preparation/load | 100.98 | 27.07 | 12.48 |
| First 5 s dictation after ready | 0.189 | — | — |
| Warm 5 s dictation | 0.156 | 0.153 | 1.520 |
| 97.106 s clip | 3.083 wall / 3.051 decode | 1.004 | 11.598 |
| Peak physical footprint | 134.9 MiB | 95.5 MiB | 1,922.1 MiB |

The compiled Core ML package already existed for the final run, so its package
compile counter was effectively zero; the measured 100.62 seconds inside the
runtime was Neural Engine function loading/preparation. An earlier run measured
124.63 seconds for the same preparation, while an earlier first-ever run measured
1.17 seconds for package compilation plus 105.30 seconds for its then-selected
function. This supports the UI's warning that initial preparation can take
roughly one to two minutes, while same-process transcriptions are fast.

The pinned download is 345,012,107 bytes. After Core ML compilation, the model
plus content-addressed compiled cache occupied 676,914,435 logical bytes
(approximately 646 MiB). The on-demand download itself was observed at roughly
two minutes on this connection, but network time is not used as a performance
claim.

Short-clip outputs:

- Phonon-2: `And so, my fellow Americans, ask not`
- Parakeet v3: `And so, my fellow Americans, ask not!`
- Whisper large-v3-turbo: `and so my fellow Americans, ask not`

Against `OpenSuperWhisperTests/Fixtures/long_en.txt`, a local lowercase,
punctuation-stripped word edit-distance check produced 1/292 errors (0.34%) for
Phonon, 2/292 (0.68%) for Parakeet, and 93/292 (31.85%) for Whisper. These are
single-fixture observations, not general WER claims. Phonon returned 292 word
timings (from `Today`, 0.16-0.32 s, through `breaks.`, 96.56-97.04 s). Full
transcripts and timing arrays are preserved in `docs/phonon-2-benchmark-m5.json`.
Upstream WER and speed figures remain vendor claims and are not repeated as
locally established facts.

## Manual reproduction

The benchmark is intentionally opt-in because it downloads/loads real models:

```sh
touch /tmp/run-osw-phonon-benchmark
trap 'rm -f /tmp/run-osw-phonon-benchmark' EXIT
xcodebuild test \
  -project OpenSuperWhisper.xcodeproj \
  -scheme OpenSuperWhisper \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OpenSuperWhisperTests/PhononBenchmarkTests/testM5LocalEngineComparisonAndPhononAppPath
```

The coordinator launches one fresh test process per engine and writes the raw
report to `/tmp/osw-phonon-benchmark.json`. It does not copy or replace
`/Applications/OpenSuperWhisper.app`.
