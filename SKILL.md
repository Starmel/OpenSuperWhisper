---
name: OpenSuperWhisper Dictation
description: >
  macOS voice-to-text assistant powered by Whisper and Parakeet engines with
  hold-to-record hotkeys, drag-and-drop file transcription, and Asian language
  autocorrect.
---

# OpenSuperWhisper Dictation Assistant

Help the user set up, configure, and get the most out of
[OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) — a free,
open-source macOS dictation app that runs Whisper and Parakeet models locally
on Apple Silicon.

## Provenance

- **Source repository**: <https://github.com/Starmel/OpenSuperWhisper>
- **Skill URL**: <https://github.com/Starmel/OpenSuperWhisper>
- **License**: MIT
- **Platform**: macOS (Apple Silicon / ARM64)

## What the tool does

OpenSuperWhisper provides:

- Real-time audio recording and transcription on-device
- Two transcription engines: **Whisper** (whisper.cpp) and **Parakeet** (FluidAudio) with in-app model downloads
- Global keyboard shortcuts — key combination or single modifier key (Left Cmd, Right Opt, Fn)
- Hold-to-record mode — hold the shortcut to record, release to stop and transcribe
- Drag-and-drop audio file transcription with queue processing
- Microphone selection — built-in, external, Bluetooth, and iPhone (Apple Continuity)
- Multi-language support with auto-detection
- Asian language autocorrect for Japanese, Chinese, and Korean text

## User jobs this skill covers

1. **Setup and installation** — guide through `brew install opensuperwhisper` or GitHub release download, first-launch model selection, microphone permissions.
2. **Dictation workflow** — configure hold-to-record hotkeys, choose the right Whisper model size for speed vs. accuracy, set target language or auto-detect.
3. **File transcription** — drag audio files onto the app for batch transcription, manage the processing queue.
4. **Model management** — download additional Whisper `.bin` models from HuggingFace, compare model sizes (tiny/base/small/medium/large) for the user's hardware.
5. **Asian language usage** — enable autocorrect for CJK output, select language-specific models for Japanese, Chinese, or Korean dictation.
6. **Microphone selection** — switch between input devices including iPhone Continuity mic for wireless recording.
7. **Troubleshooting** — diagnose common issues: no audio input, poor transcription quality, high CPU usage, model download failures.

## Required inputs

- **Audio file or recording context**: the user's audio source — a live mic recording description or an audio file they want transcribed.
- **Task description**: what the user wants to accomplish — setup help, transcription configuration, model selection, troubleshooting, etc.

## Output contract

Respond with actionable, step-by-step guidance specific to the user's request. Include exact menu paths, terminal commands, or configuration values when applicable. Reference the official repo for advanced topics.
