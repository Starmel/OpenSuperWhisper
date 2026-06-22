# OpenSuperWhisper

> **Community fork maintained by [My-Monkey](https://my-monkey.fr).** A maintained successor to
> [`Starmel/OpenSuperWhisper`](https://github.com/Starmel/OpenSuperWhisper) (MIT), revived to land the
> backlog of pending contributions and keep the project moving. Thanks to the original author and every
> contributor — merged work credits its original authors.

OpenSuperWhisper is a macOS application that provides real-time audio transcription using the Whisper model. It offers a seamless way to record and transcribe audio with customizable settings and keyboard shortcuts.

<p align="center">
<img src="docs/image.png" width="400" /> <img src="docs/image_indicator.png" width="400" />
</p>

## Features

- 🎙️ Real-time audio recording and transcription
- 🧠 Three transcription engines, all on-device: [Whisper](https://github.com/ggerganov/whisper.cpp), [Parakeet](https://github.com/AntinomyCollective/FluidAudio), and [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) (Chinese/Cantonese/English/Japanese/Korean, via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) — download models directly from the app
- ⌨️ Global keyboard shortcuts — key combination or single modifier key (e.g. Left ⌘, Right ⌥, Fn)
- ✊ Hold-to-record mode — hold the shortcut to record, release to stop
- 📁 Drag & drop audio files for transcription with queue processing
- 🎤 Microphone selection — switch between built-in, external, Bluetooth and iPhone (Apple Continuity) mics from the menu bar
- 🌍 Support for many languages with auto-detection — including Hebrew (with an [ivrit.ai](https://www.ivrit.ai/) fine-tuned model)
- 📖 Custom dictionary — fix proper nouns and jargon with your own replacements (works with both engines; biases Whisper recognition)
- 👀 Live transcription preview — see the text build up in the indicator as you speak (Parakeet)
- 🤖 AI Cleanup — optionally tidy punctuation/casing through a local [Ollama](https://ollama.com) model, fully on-device (opt-in)
- 🎯 Configurable recording indicator — cursor, screen edges, or a **Notch / Dynamic Island** mode (real notch or faux-notch)
- 🧹 Cleaner output — optionally remove filler words (um, uh…) and never paste "No speech detected"
- 🤐 Privacy & history — disable transcription history, or set retention limits (max count / age)
- 🚀 Lifecycle — launch at login and/or start hidden in the menu bar
- 🔇 While recording — optionally pause other apps' media or lower the system volume
- 🪝 Post-record hook — run your own shell command after each transcription (text + audio path via env vars / JSON)
- 🆕 In-app updates — an Updates tab (check + release notes) and a menu-bar "Check for Updates"
- 🇯🇵🇨🇳🇰🇷 Asian language autocorrect ([autocorrect](https://github.com/huacnlee/autocorrect))

## Installation

**Homebrew** (recommended):

```sh
brew install --cask my-monkeys/tap/opensuperwhisper
```

> Use the full `my-monkeys/tap/` path — the bare name `opensuperwhisper` resolves to the original
> (unmaintained) cask in homebrew-cask, not this fork.

Or download the latest **notarized** `.dmg` from the [Releases page](https://github.com/my-monkeys/OpenSuperWhisper/releases), or [build it from source](#building-locally).

## Requirements

- macOS 14 (Sonoma) or later
- **Apple Silicon or Intel** — `brew install` picks the right build automatically. The Intel
  (x86_64) build ships Whisper + Parakeet; SenseVoice is Apple-Silicon-only (its onnxruntime
  dependency ships arm64-only).

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the repository
2. Create a new issue with detailed information about your problem
3. Include system information and logs when reporting bugs

## Building locally

To build locally, you'll need:

    git clone git@github.com:my-monkeys/OpenSuperWhisper.git
    cd OpenSuperWhisper
    git submodule update --init --recursive
    brew install cmake libomp rust ruby
    gem install xcpretty
    ./run.sh build

In case of problems, consult `.github/workflows/build.yml` which is our CI workflow
where the app gets built automatically on GitHub's CI.

Maintainers: see [`docs/RELEASING.md`](docs/RELEASING.md) for the notarized-release + Homebrew flow.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

### Contribution TODO list

- [x] Streaming transcription — live preview while speaking
- [x] Custom dictionary / keyword boosting ([#19](https://github.com/Starmel/OpenSuperWhisper/issues/19))
- [x] Background app ([#8](https://github.com/Starmel/OpenSuperWhisper/issues/8))
- [x] Support long-press single key audio recording ([#18](https://github.com/Starmel/OpenSuperWhisper/issues/18))
- [x] AI cleanup — optional local-LLM post-processing
- [x] Configurable indicator position + Notch / Dynamic Island mode
- [x] Notarized Developer ID build + Homebrew cask
- [x] Sparkle auto-update (in-place download & install)
- [x] SenseVoice engine — local multilingual ASR via sherpa-onnx ([#145](https://github.com/Starmel/OpenSuperWhisper/issues/145))
- [x] Internationalization / localization — initial French
- [x] Intel macOS compatibility ([#15](https://github.com/Starmel/OpenSuperWhisper/issues/15)) — separate x86_64 build (Whisper + Parakeet)
- [ ] CLI ([#150](https://github.com/Starmel/OpenSuperWhisper/issues/150))
- [ ] Agent mode ([#14](https://github.com/Starmel/OpenSuperWhisper/issues/14))

## License

OpenSuperWhisper is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Whisper Models

You can download Whisper model files (`.bin`) from the [Whisper.cpp Hugging Face repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Place the downloaded `.bin` files in the app's models directory. On first launch, the app will attempt to copy a default model automatically, but you can add more models manually.
