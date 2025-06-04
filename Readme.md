# OpenSuperWhisper

OpenSuperWhisper is a macOS application that provides real-time audio transcription using the Whisper model. It offers a seamless way to record and transcribe audio with customizable settings and keyboard shortcuts.

<p align="center">
<img src="docs/image.png" width="400" /> <img src="docs/image_indicator.png" width="400" />
</p>

Free alternative to paid services like:
* https://tryvoiceink.com
* https://goodsnooze.gumroad.com/l/macwhisper
* and etc..

## Installation

```shell
brew update # Optional
brew install opensuperwhisper
```

Or from [github releases page](https://github.com/Starmel/OpenSuperWhisper/releases).

## Features

- 🎙️ Real-time audio recording and transcription
- ⌨️ Global keyboard shortcuts for quick recording (use ```cmd + ` ```)
- 🌍 Support for multiple languages with auto-detection (not tested, but probably works)
- 🔄 Optional translation to English (for better translation add initial prompt with english sentences)
- 💾 Local storage of recordings with transcriptions
- 🎛️ Advanced transcription settings (not tested)

## Requirements

- macOS (Apple Silicon/ARM64)

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the repository
2. Create a new issue with detailed information about your problem
3. Include system information and logs when reporting bugs

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

## License

OpenSuperWhisper is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Whisper Models

You can download Whisper model files (`.bin`) from the [Whisper.cpp Hugging Face repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Place the downloaded `.bin` files in the app's models directory. On first launch, the app will attempt to copy a default model automatically, but you can add more models manually.

## How to Verify Model Auto-Repair

To check that the auto-repair feature is working:

1. Delete all `.bin` model files from the models directory. You can open this folder from the app's Settings ("Open Folder" button next to "Models Directory").
2. Restart the app.
3. The default model (`ggml-tiny.en.bin`) should be restored automatically, and the model selector will no longer be empty.

If you want to add more models, simply download them from the link above and place them in the models directory.
